//
//  RtcManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import AppKit

/// Manages RTC leases, connection waits, cancellation, and event validity.
final class RtcManager: RtcManaging, @unchecked Sendable {

    /// The default room join timeout, in nanoseconds.
    static let joinTimeoutNanoseconds: UInt64 = 15000000000

    /// The exclusive engine lease provider.
    private let engineManager: RtcEngineManager

    /// The room join timeout, in nanoseconds.
    private let joinTimeout: UInt64

    /// The lock protecting room, lease, and initialization state.
    private let stateLock = NSLock()

    /// The lock serializing compound RTC operations.
    private let operationLock = NSRecursiveLock()

    /// Camera calls can block inside Agora; serialize them independently of room operations.
    private let cameraOperationLock = NSRecursiveLock()

    /// The engine lease held by this manager.
    private var engineLease: RtcEngineLease?

    /// The active room and its validity.
    private var activeRoom: RoomContext?

    /// The pending room join request.
    private var pendingJoin: PendingJoin?

    /// The listener for room and remote stream events.
    private weak var eventListener: (any RtcEventListener)?

    /// The listener for RTC quality and media statistics.
    private weak var qualityListener: (any RtcQualityListener)?

    /// The shared engine initialization operation.
    private var initialization: Initialization?

    /// Camera and room calls can block independently; preview commands must not wait on AppKit's thread.
    @MainActor private var previewCommandID = UUID()

    /// The pending main-actor retry task for a deferred preview operation.
    @MainActor private var previewCommand: Task<Void, Never>?

    /// The canvas requested by the latest preview attachment.
    @MainActor private weak var requestedPreviewView: NSView?

    /// Creates an RTC manager with a room join timeout.
    init(
        engineManager: RtcEngineManager = .shared,
        joinTimeoutNanoseconds: UInt64 = RtcManager.joinTimeoutNanoseconds
    ) {
        self.engineManager = engineManager
        joinTimeout = joinTimeoutNanoseconds
    }

    /// Acquires an exclusive RTC engine lease and completes initialization.
    ///
    /// - Throws: An error if lease waiting is cancelled or engine initialization fails.
    func initialize() async throws {
        guard !Task.isCancelled else {
            throw Self.cancelledError(operation: "RTC initialization")
        }
        let waiterID = UUID()
        let initialization = stateLock.withLock { () -> Initialization? in
            guard engineLease == nil else {
                return nil
            }
            if var initialization {
                initialization.waiterIDs.insert(waiterID)
                self.initialization = initialization
                return initialization
            }

            let initialization = Initialization(
                id: UUID(),
                task: Task {
                    try await engineManager.acquire()
                },
                waiterIDs: [waiterID]
            )
            self.initialization = initialization
            return initialization
        }
        guard let initialization else {
            return
        }

        do {
            let lease = try await withTaskCancellationHandler {
                try await initialization.task.value
            } onCancel: {
                self.cancelInitializationWaiter(
                    initializationID: initialization.id,
                    waiterID: waiterID
                )
            }
            try await finishInitialization(
                initializationID: initialization.id,
                lease: lease
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            clearInitialization(id: initialization.id)
            throw Self.cancelledError(operation: "RTC initialization")
        } catch {
            clearInitialization(id: initialization.id)
            throw error
        }
    }

    /// Destroys the RTC engine and releases resources.
    func destroy() async {
        await leaveRoom()
        let resources = cameraOperationLock.withLock {
            operationLock.withLock {
                stateLock.withLock { () -> (RtcEngineLease?, Initialization?) in
                    let resources = (engineLease, initialization)
                    engineLease = nil
                    initialization = nil
                    return resources
                }
            }
        }

        resources.1?.task.cancel()
        if let lease = resources.0 {
            await engineManager.release(lease)
        }
    }

    /// Applies upstream video encoding configuration.
    ///
    /// - Parameter configuration: Dimensions, frame rate, bitrate, and encoding preferences.
    ///
    /// - Throws: An error if the vendor engine rejects configuration.
    func configureVideoEncoding(
        _ configuration: VideoEncodingConfiguration
    ) throws {
        guard configuration.width > 0, configuration.height > 0, configuration.frameRate > 0 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Video width, height, and frame rate must be positive"
            )
        }
        try withEngine { try $0.configureVideoEncoding(configuration) }
    }

    /// Sets camera upstream mirroring, retaining the setting across encoder reconfiguration.
    ///
    /// - Parameter mirror: Whether to mirror the encoded camera stream.
    ///
    /// - Throws: An error if the engine is unavailable or rejects the setting.
    func configureLocalVideoMirror(
        _ mirror: Bool
    ) throws {
        try withEngine { try $0.configureLocalVideoMirror(mirror) }
    }

    /// Enables external video input.
    ///
    /// - Throws: An error if video source configuration fails.
    func useExternalVideoSource() throws {
        try withEngine { try $0.useExternalVideoSource() }
    }

    /// Starts native capture using the engine under camera operation ownership.
    func startCameraCapture(
        configuration: RtcCameraConfiguration,
        previewReadyListener: @escaping @Sendable () -> Void,
        errorListener: @escaping XmaxErrorListener
    ) throws {
        try withCameraEngine {
            try $0.startCameraCapture(
                configuration: configuration,
                previewReadyListener: previewReadyListener,
                errorListener: errorListener
            )
        }
    }

    /// Switches the active native camera under camera operation ownership.
    func switchCameraCapture(
        to deviceID: String
    ) throws {
        try withCameraEngine { try $0.switchCameraCapture(to: deviceID) }
    }

    /// Updates native camera capture without replacing its engine or preview canvas.
    func updateCameraCapture(
        videoFormat: VideoFormat,
        frameRate: Int
    ) throws {
        try withCameraEngine {
            try $0.updateCameraCapture(
                videoFormat: videoFormat,
                frameRate: frameRate
            )
        }
    }

    /// Stops native camera capture without requiring an active engine.
    func stopCameraCapture() throws {
        try cameraOperationLock.withLock {
            let engine = stateLock.withLock { engineLease?.engine }
            try engine?.stopCameraCapture()
        }
    }

    /// Requests native rendering in an AppKit canvas, deferring work when engine locks are busy.
    @MainActor
    func attachCameraPreview(
        to view: NSView,
        contentMode: VideoContentMode,
        mirrored: Bool
    ) throws {
        requestedPreviewView = view
        try submitPreviewCommand {
            try $0.attachCameraPreview(
                to: view,
                contentMode: contentMode,
                mirrored: mirrored
            )
        }
    }

    /// Detaches the requested canvas and discards stale preview requests.
    @MainActor
    func detachCameraPreview(
        from view: NSView
    ) throws {
        guard requestedPreviewView === view else { return }
        requestedPreviewView = nil
        try submitPreviewCommand { try $0.detachCameraPreview(from: view) }
    }

    /// Applies the latest preview operation immediately or retries it without blocking the main actor.
    @MainActor
    private func submitPreviewCommand(
        _ operation: @escaping @MainActor @Sendable (any RtcPlatform) throws -> Void
    )
        throws
    {
        previewCommand?.cancel()
        let id = UUID()
        previewCommandID = id
        if try tryPreviewCommand(operation) { return }
        previewCommand = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self, previewCommandID == id else { return }
                do {
                    if try tryPreviewCommand(operation) { return }
                } catch {
                    XmaxRealtimeVideoView.logRenderingFailure(
                        title: "Failed to bind native camera preview",
                        error: error
                    )
                    return
                }
            }
        }
    }

    /// Attempts a preview operation without blocking and reports whether engine locks were available.
    @MainActor
    private func tryPreviewCommand(
        _ operation: @MainActor (any RtcPlatform) throws -> Void
    ) throws -> Bool {
        guard cameraOperationLock.try() else { return false }
        defer { cameraOperationLock.unlock() }
        guard operationLock.try() else { return false }
        defer { operationLock.unlock() }
        if let platform = stateLock.withLock({ engineLease?.engine }) { try operation(platform) }
        return true
    }

    /// Switches to microphone input and starts capture.
    ///
    /// - Throws: An error on audio source switching or capture failure.
    func startAudioCapture() throws {
        try withEngine { try $0.startAudioCapture() }
    }

    /// Stops microphone capture.
    ///
    /// - Throws: An error if the vendor engine fails to stop capture.
    func stopAudioCapture() throws {
        try withOptionalEngine { try $0.stopAudioCapture() }
    }

    /// Enables external PCM input.
    ///
    /// - Throws: An error if external audio track creation fails.
    func startExternalAudioSource() throws {
        try withEngine { try $0.startExternalAudioSource() }
    }

    /// Stops external PCM input and releases the audio track.
    ///
    /// - Throws: An error if audio track release fails.
    func stopExternalAudioSource() throws {
        try withOptionalEngine { try $0.stopExternalAudioSource() }
    }

    /// Pushes an external video frame.
    ///
    /// - Parameter frame: The SDK's neutral video frame.
    ///
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalVideoFrame(
        _ frame: VideoFrame
    ) throws {
        try withEngine { try $0.pushExternalVideoFrame(frame) }
    }

    /// Pushes an external audio frame.
    ///
    /// - Parameter frame: Timestamped 10 ms PCM data.
    ///
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalAudioFrame(
        _ frame: AudioFrame
    ) throws {
        try withEngine { try $0.pushExternalAudioFrame(frame) }
    }

    /// Joins an RTC room and waits for connection.
    ///
    /// - Parameter configuration: The room, user identifier, and token configuration.
    ///
    /// - Throws: An error on unavailable engine, join failure, timeout, or cancellation.
    func joinRoom(
        configuration: RoomJoinConfiguration
    ) async throws {
        guard !configuration.roomID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !configuration.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "RTC room ID and user account cannot be empty"
            )
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginJoin(
                    id: id,
                    configuration: configuration,
                    continuation: continuation
                )
            }
        } onCancel: {
            self.failPendingJoin(
                id: id,
                error: Self.cancelledError(operation: "RTC join room")
            )
        }
    }

    /// Leaves the current RTC room.
    func leaveRoom() async {
        operationLock.withLock {
            let resources = stateLock.withLock { () -> (RoomContext?, PendingJoin?) in
                let result = (activeRoom, pendingJoin)
                activeRoom = nil
                pendingJoin = nil
                return result
            }
            resources.1?.timeoutTask?.cancel()
            resources.1?.continuation.resume(
                throwing: Self.cancelledError(operation: "RTC join room")
            )
            tearDownRoom(resources.1?.context)
            tearDownRoom(resources.0)
        }
    }

    /// Publishes the local video stream.
    ///
    /// - Throws: An error if the room is unavailable or video publication fails.
    func publishLocalVideo() throws {
        try withRoom { try $0.publishLocalVideo(true) }
    }

    /// Stops local video publication.
    ///
    /// - Throws: An error if the room is unavailable or stopping video publication fails.
    func unpublishLocalVideo() throws {
        try withOptionalRoom { try $0.publishLocalVideo(false) }
    }

    /// Publishes the local audio stream.
    ///
    /// - Throws: An error if the room is unavailable or audio publication fails.
    func publishLocalAudio() throws {
        try withRoom { try $0.publishLocalAudio(true) }
    }

    /// Stops local audio publication.
    ///
    /// - Throws: An error if the room is unavailable or stopping audio publication fails.
    func unpublishLocalAudio() throws {
        try withOptionalRoom { try $0.publishLocalAudio(false) }
    }

    /// Sets video subscription state for a remote user.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - subscribe: Whether to subscribe to the video stream.
    ///
    /// - Throws: An error on unavailable room, user mapping failure, or subscription configuration failure.
    func subscribeRemoteVideo(
        userID: String,
        subscribe: Bool
    ) throws {
        try withRoom {
            try $0.subscribeRemoteVideo(
                userID: userID,
                subscribe: subscribe
            )
        }
    }

    /// Sets audio subscription state for a remote user.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - subscribe: Whether to subscribe to the audio stream.
    ///
    /// - Throws: An error on unavailable room, user mapping failure, or subscription configuration failure.
    func subscribeRemoteAudio(
        userID: String,
        subscribe: Bool
    ) throws {
        try withRoom {
            try $0.subscribeRemoteAudio(
                userID: userID,
                subscribe: subscribe
            )
        }
    }

    /// Sets audio playback volume for a remote user.
    ///
    /// - Parameters:
    ///   - volume: The playback volume from 0 to 100.
    ///   - userID: The remote RTC user identifier.
    ///
    /// - Throws: An error if the room is unavailable or volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Int,
        for userID: String
    ) throws {
        guard (0...100).contains(volume) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "RTC audio volume must be between 0 and 100"
            )
        }
        try withRoom {
            try $0.setRemoteAudioVolume(
                volume,
                for: userID
            )
        }
    }

    /// Sets the decoded frame listener for a remote stream.
    ///
    /// - Parameters:
    ///   - listener: The decoded frame callback; `nil` clears it.
    ///   - stream: The remote stream to observe.
    ///
    /// - Throws: An error if the room is unavailable or frame listener configuration fails.
    func setRemoteVideoFrameListener(
        _ listener: RtcRemoteVideoFrameListener?,
        for stream: RemoteStream
    ) throws {
        try operationLock.withLock {
            guard let context = stateLock.withLock({ activeRoom }), context.roomID == stream.roomID
            else {
                if listener == nil { return }
                throw XmaxError(
                    code: .rtcError,
                    message: "Remote stream is unavailable"
                )
            }

            let id = context.id
            let guardedListener: RtcRemoteVideoFrameListener?
            if let listener {
                guardedListener = { [weak self] frame in
                    guard let self, self.stateLock.withLock({ self.activeRoom?.id == id }) else {
                        return
                    }
                    listener(frame)
                }
            } else {
                guardedListener = nil
            }
            try context.room.setRemoteVideoFrameListener(
                guardedListener,
                for: stream.userID
            )
        }
    }

    /// Sets a remote PCM listener guarded by the current room's connection lifetime.
    ///
    /// - Parameters:
    ///   - listener: The owned audio handler, or `nil` to remove it.
    ///   - stream: The remote result stream.
    ///
    /// - Throws: An error if the room or remote account is unavailable.
    func setRemoteAudioFrameListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for stream: RemoteStream
    ) throws {
        try operationLock.withLock {
            guard let context = stateLock.withLock({ activeRoom }),
                  context.roomID == stream.roomID
            else {
                if listener == nil {
                    return
                }
                throw XmaxError(
                    code: .rtcError,
                    message: "Remote audio stream is unavailable"
                )
            }

            let id = context.id
            let guardedListener: RtcRemoteAudioFrameListener?
            if let listener {
                guardedListener = { [weak self] frame in
                    guard let self, stateLock.withLock({ activeRoom?.id == id }) else {
                        return
                    }
                    listener(frame)
                }
            } else {
                guardedListener = nil
            }

            try context.room.setRemoteAudioFrameListener(
                guardedListener,
                for: stream.userID
            )
        }
    }

    /// Sends a message to the active RTC room.
    ///
    /// - Parameters:
    ///   - message: The complete JSON message.
    ///   - reportFailure: Whether asynchronous send failures are reported as room failures.
    ///   - key: The key replacing older, unsent messages with the same key.
    ///
    /// - Returns: The task for awaiting this message's send result.
    ///
    /// - Throws: An error if enqueueing fails.
    @discardableResult
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool = true,
        replacingPendingMessage key: String? = nil
    ) throws -> Task<Void, any Error> {
        try withRoom {
            try $0.sendRoomMessage(
                message,
                reportFailure: reportFailure,
                replacingPendingMessage: key
            )
        }
    }

    /// Drops coalescible messages not yet sent by the active room.
    ///
    /// - Parameter key: The coalescing key, or `nil` for all coalescible messages.
    func discardPendingMessages(
        key: String?
    ) {
        operationLock.withLock {
            let room = stateLock.withLock {
                activeRoom?.room
            }
            room?.discardPendingMessages(key: key)
        }
    }

    /// Waits for queued room signals to finish sending.
    ///
    /// - Throws: An error on unavailable room, send failure, or cancelled waiting.
    func awaitPendingMessages() async throws {
        let room = try operationLock.withLock { try requireRoom().room }
        try await room.awaitPendingMessages()
    }

    /// Sets the RTC connection and media event listener.
    ///
    /// - Parameter listener: The event listener; `nil` clears it.
    func setEventListener(
        _ listener: (any RtcEventListener)?
    ) {
        stateLock.withLock { eventListener = listener }
    }

    /// Sets the RTC network and media quality listener.
    ///
    /// - Parameter listener: The quality listener; `nil` clears it.
    func setQualityListener(
        _ listener: (any RtcQualityListener)?
    ) {
        stateLock.withLock { qualityListener = listener }
    }
}

private extension RtcManager {

    /// Stores a shared initialization task and its remaining waiters.
    struct Initialization {

        /// The initialization revision identifier.
        let id: UUID

        /// The shared engine acquisition task.
        let task: Task<RtcEngineLease, any Error>

        /// The callers awaiting this initialization.
        var waiterIDs: Set<UUID>
    }

    /// Associates connection identity with a platform room to isolate late events from old connections.
    final class RoomContext: Sendable {

        /// The connection identifier.
        let id: UUID

        /// The RTC room identifier for this context.
        let roomID: String

        /// The connection's platform room.
        let room: any RtcRoom

        /// Associates a connection identity with its platform room.
        init(
            id: UUID,
            roomID: String,
            room: any RtcRoom
        ) {
            self.id = id
            self.roomID = roomID
            self.room = room
        }
    }

    /// Stores a pending room join, continuation, and timeout task.
    final class PendingJoin: @unchecked Sendable {

        /// The room awaiting connection.
        let context: RoomContext

        /// The continuation awaiting room join.
        let continuation: CheckedContinuation<Void, any Error>

        /// The room join timeout task.
        var timeoutTask: Task<Void, Never>?

        /// Creates a pending room join context.
        init(
            context: RoomContext,
            continuation: CheckedContinuation<Void, any Error>
        ) {
            self.context = context
            self.continuation = continuation
        }
    }

    /// Accepts a valid engine lease or releases it if initialization is invalid.
    ///
    /// - Parameters:
    ///   - initializationID: The current initialization operation identifier.
    ///   - lease: The newly acquired engine lease.
    ///
    /// - Throws: Cancellation if initialization was cancelled or replaced.
    func finishInitialization(
        initializationID: UUID,
        lease: RtcEngineLease
    )
        async throws
    {
        let installed = operationLock.withLock {
            stateLock.withLock { () -> Bool in
                if engineLease?.id == lease.id { return true }
                guard initialization?.id == initializationID else { return false }
                engineLease = lease
                initialization = nil
                return true
            }
        }
        if !installed {
            await engineManager.release(lease)
            throw Self.cancelledError(operation: "RTC initialization")
        }
    }

    /// Removes an initialization waiter and cancels lease acquisition when none remain.
    ///
    /// - Parameters:
    ///   - initializationID: The initialization operation identifier.
    ///   - waiterID: The waiter identifier to cancel.
    func cancelInitializationWaiter(
        initializationID: UUID,
        waiterID: UUID
    ) {
        let task = stateLock.withLock { () -> Task<RtcEngineLease, any Error>? in
            guard var initialization,
                initialization.id == initializationID,
                initialization.waiterIDs.remove(waiterID) != nil
            else {
                return nil
            }
            guard initialization.waiterIDs.isEmpty else {
                self.initialization = initialization
                return nil
            }
            self.initialization = nil
            return initialization.task
        }
        task?.cancel()
    }

    /// Clears the matching initialization operation.
    ///
    /// - Parameter id: The initialization identifier to clear.
    func clearInitialization(
        id: UUID
    ) {
        stateLock.withLock {
            if initialization?.id == id {
                initialization = nil
            }
        }
    }

    /// Creates a room and starts join and timeout waiting.
    ///
    /// - Parameters:
    ///   - id: The unique identifier for this connection.
    ///   - configuration: The room and user connection configuration.
    ///   - continuation: The continuation resumed on join success or failure.
    func beginJoin(
        id: UUID,
        configuration: RoomJoinConfiguration,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        operationLock.withLock {
            do {
                try Task.checkCancellation()
                let engine = try requireEngine()
                guard stateLock.withLock({ activeRoom == nil && pendingJoin == nil }) else {
                    throw XmaxError(
                        code: .rtcError,
                        message: "RTC room is already active"
                    )
                }

                let room = try engine.createRoom(roomID: configuration.roomID)
                let context = RoomContext(
                    id: id,
                    roomID: configuration.roomID,
                    room: room
                )
                let pending = PendingJoin(
                    context: context,
                    continuation: continuation
                )
                stateLock.withLock { pendingJoin = pending }
                room.setEventListener { [weak self] event in
                    self?.handleRoomEvent(
                        event,
                        id: id
                    )
                }

                pending.timeoutTask = Task { [weak self, joinTimeout] in
                    try? await Task.sleep(nanoseconds: joinTimeout)
                    guard !Task.isCancelled else { return }
                    self?.failPendingJoin(
                        id: id,
                        error: XmaxError(
                            code: .timeout,
                            message: "RTC join room timed out"
                        )
                    )
                }
                try room.join(configuration: configuration)
            } catch {
                if stateLock.withLock({ pendingJoin?.context.id == id }) {
                    failPendingJoin(
                        id: id,
                        error: XmaxError.from(error)
                    )
                } else {
                    continuation.resume(throwing: XmaxError.from(error))
                }
            }
        }
    }

    /// Handles current connection room events, ignoring invalidated connections.
    ///
    /// - Parameters:
    ///   - event: The platform room event.
    ///   - id: The connection identifier that produced the event.
    func handleRoomEvent(
        _ event: RtcRoomEvent,
        id: UUID
    ) {
        operationLock.withLock {
            guard
                let context = stateLock.withLock({
                    activeRoom?.id == id ? activeRoom : pendingJoin?.context
                }),
                context.id == id
            else { return }

            switch event {
            case .joined:
                finishJoin(context)
            case .publication(
                let userID,
                let published
            ):
                notifyPublication(
                    id: id,
                    userID: userID,
                    published: published
                )
            case .failure(let error):
                failRoom(
                    id: id,
                    error: error
                )
            case .quality(
                let uplink,
                let downlink
            ):
                notifyQuality(id: id) {
                    $0.onNetworkQuality(
                        uplink: uplink,
                        downlink: downlink
                    )
                }
            case .uplinkVideoStatistics(let statistics):
                notifyQuality(id: id) { $0.onUplinkVideoStatistics(statistics) }
            case .downlinkVideoStatistics(let statistics):
                notifyQuality(id: id) { $0.onDownlinkVideoStatistics(statistics) }
            case .performance(
                let limited,
                let width,
                let height,
                let fps
            ):
                notifyQuality(id: id) {
                    $0.onPerformanceAlarm(
                        limited: limited,
                        suggestedWidth: width,
                        suggestedHeight: height,
                        suggestedFrameRate: fps
                    )
                }
            }
        }
    }

    /// Promotes a pending room to active and resumes the join call.
    ///
    /// - Parameter context: The successfully connected room context.
    func finishJoin(
        _ context: RoomContext
    ) {
        guard let pending = stateLock.withLock({ pendingJoin }), pending.context === context else {
            return
        }
        stateLock.withLock {
            activeRoom = context
            pendingJoin = nil
        }
        pending.timeoutTask?.cancel()
        pending.continuation.resume()
    }

    /// Ends the matching join wait and releases an unconnected room.
    ///
    /// - Parameters:
    ///   - id: The connection identifier to finish.
    ///   - error: The error returned to the join caller.
    func failPendingJoin(
        id: UUID,
        error: any Error
    ) {
        operationLock.withLock {
            let pending = stateLock.withLock { () -> PendingJoin? in
                guard pendingJoin?.context.id == id else { return nil }
                let value = pendingJoin
                pendingJoin = nil
                return value
            }
            guard let pending else { return }
            pending.timeoutTask?.cancel()
            tearDownRoom(pending.context)
            pending.continuation.resume(throwing: error)
        }
    }

    /// Reports connection failure to the join caller or current connection listener.
    ///
    /// - Parameters:
    ///   - id: The failed connection identifier.
    ///   - error: The connection failure reason.
    func failRoom(
        id: UUID,
        error: XmaxError
    ) {
        if stateLock.withLock({ pendingJoin?.context.id == id }) {
            failPendingJoin(
                id: id,
                error: error
            )
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let listener = stateLock.withLock { activeRoom?.id == id ? eventListener : nil }
            listener?.onRtcFailure(error)
        }
    }

    /// Reports video publication changes for a valid connection on the main thread.
    ///
    /// - Parameters:
    ///   - id: The connection identifier.
    ///   - userID: The remote user identifier.
    ///   - published: Whether remote video is published.
    func notifyPublication(
        id: UUID,
        userID: String,
        published: Bool
    ) {
        guard stateLock.withLock({ activeRoom?.id == id }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let listener = stateLock.withLock { activeRoom?.id == id ? eventListener : nil }
            listener?.onRemoteVideoPublished(
                userID: userID,
                published: published
            )
        }
    }

    /// Forwards quality events to the current connection listener on the main thread.
    ///
    /// - Parameters:
    ///   - id: The connection identifier.
    ///   - action: The notification to invoke on the quality listener.
    func notifyQuality(
        id: UUID,
        _ action: @escaping @MainActor @Sendable (any RtcQualityListener) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let listener = stateLock.withLock { activeRoom?.id == id ? qualityListener : nil }
            if let listener { action(listener) }
        }
    }

    /// Removes room event listeners and destroys the room.
    ///
    /// - Parameter context: The room context to release; `nil` does nothing.
    func tearDownRoom(
        _ context: RoomContext?
    ) {
        context?.room.setEventListener(nil)
        context?.room.destroy()
    }

    /// Gets the RTC engine held by the current valid lease.
    ///
    /// - Returns: The current RTC platform engine.
    ///
    /// - Throws: An error if the engine is uninitialized.
    func requireEngine() throws -> any RtcPlatform {
        guard let engine = stateLock.withLock({ engineLease?.engine }) else {
            throw XmaxError(
                code: .rtcError,
                message: "RTC engine is not initialized"
            )
        }
        return engine
    }

    /// Gets the connected room context.
    ///
    /// - Returns: The active room context.
    ///
    /// - Throws: An error if no room has been joined.
    func requireRoom() throws -> RoomContext {
        guard let context = stateLock.withLock({ activeRoom }) else {
            throw XmaxError(
                code: .rtcError,
                message: "RTC room is not joined"
            )
        }
        return context
    }

    /// Uses the current RTC engine under the operation lock.
    ///
    /// - Parameter operation: The synchronous engine operation.
    ///
    /// - Returns: The operation result.
    ///
    /// - Throws: An error if the engine is unavailable or the operation fails.
    func withEngine<T>(
        _ operation: (any RtcPlatform) throws -> T
    ) throws -> T {
        try operationLock.withLock { try operation(requireEngine()) }
    }

    /// Keeps the lease alive for camera work without holding the room control lock.
    /// Destruction waits for the camera lock before releasing the engine lease.
    func withCameraEngine<T>(
        _ operation: (any RtcPlatform) throws -> T
    ) throws -> T {
        try cameraOperationLock.withLock {
            let engine = try requireEngine()
            return try operation(engine)
        }
    }

    /// Executes synchronously if an engine exists.
    ///
    /// - Parameter operation: The engine operation; skipped without an engine.
    ///
    /// - Throws: An error if the engine operation fails.
    func withOptionalEngine(
        _ operation: (any RtcPlatform) throws -> Void
    ) throws {
        try operationLock.withLock {
            if let engine = stateLock.withLock({ engineLease?.engine }) { try operation(engine) }
        }
    }

    /// Uses the current RTC room under the operation lock.
    ///
    /// - Parameter operation: The synchronous room operation.
    ///
    /// - Returns: The operation result.
    ///
    /// - Throws: An error if the room is unavailable or the operation fails.
    func withRoom<T>(
        _ operation: (any RtcRoom) throws -> T
    ) throws -> T {
        try operationLock.withLock { try operation(requireRoom().room) }
    }

    /// Executes synchronously if an active room exists.
    ///
    /// - Parameter operation: The room operation; skipped without a room.
    ///
    /// - Throws: An error if the room operation fails.
    func withOptionalRoom(
        _ operation: (any RtcRoom) throws -> Void
    ) throws {
        try operationLock.withLock {
            if let context = stateLock.withLock({ activeRoom }) { try operation(context.room) }
        }
    }

    /// Creates an RTC operation cancellation error.
    ///
    /// - Parameter operation: The cancelled operation name.
    ///
    /// - Returns: A cancellation error including the operation name.
    static func cancelledError(
        operation: String
    ) -> XmaxError {
        XmaxError(
            code: .cancelled,
            message: "\(operation) was cancelled"
        )
    }
}

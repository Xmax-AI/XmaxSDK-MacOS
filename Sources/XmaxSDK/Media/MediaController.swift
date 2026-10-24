//
//  MediaController.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Coordinates local media ownership and the RTC engine lifecycle.
actor MediaController: MediaControlling {
    /// An engine acquired before local-source creation belongs to the combined startup lifecycle.
    private var hasPreparedRTC = false
    private var captureStopOperation: LocalMediaStopOperation?

    /// Foundation components
    private let rtcManager: any RtcManaging

    /// Local media components
    private let cameraController: any CameraControlling
    private let externalController: (any ExternalVideoControlling)?
    private let interactionController: any InteractionControlling

    /// Local media resources
    private var activeSource: ActiveLocalMediaSource?

    /// Concurrency control
    private var mediaOperation: LocalMediaOperation?
    private var stopOperation: LocalMediaStopOperation?

    /// Creates and connects camera and media interaction controllers.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC engine and media adapter.
    ///   - mediaService: The media service providing model dimension rules.
    ///   - videoFrameListener: The callback receiving local video frames.
    ///   - requestingFrames: Whether generation currently requires external input frames.
    ///   - errorListener: The callback receiving media runtime errors.
    ///   - interactionListener: The callback receiving video pixel interaction coordinates.
    @MainActor
    init(
        rtcManager: any RtcManaging,
        mediaService: any MediaServicing = MediaService(),
        videoFrameListener: @escaping MediaVideoFrameListener,
        requestingFrames: @escaping @Sendable () -> Bool,
        errorListener: @escaping XmaxErrorListener,
        interactionListener: @escaping InteractionListener
    ) {
        self.rtcManager = rtcManager
        cameraController = CameraController(
            rtcManager: rtcManager,
            mediaService: mediaService,
            videoFrameListener: videoFrameListener,
            errorListener: errorListener
        )
        externalController = ExternalVideoController(
            rtcManager: rtcManager,
            mediaService: mediaService,
            requestingFrames: requestingFrames,
            videoFrameListener: videoFrameListener,
            errorListener: errorListener
        )
        interactionController = InteractionController(
            listener: interactionListener
        )
    }

    /// Creates a unified media controller with the specified components.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC engine and media adapter.
    ///   - cameraController: The camera media controller.
    ///   - externalController: The external video input controller.
    ///   - interactionListener: The callback receiving video pixel interaction coordinates.
    init(
        rtcManager: any RtcManaging,
        cameraController: any CameraControlling,
        externalController: (any ExternalVideoControlling)? = nil,
        interactionListener: @escaping InteractionListener = { _, _ in }
    ) {
        self.rtcManager = rtcManager
        self.cameraController = cameraController
        self.externalController = externalController
        interactionController = InteractionController(
            listener: interactionListener
        )
    }

    /// Lists currently available camera devices.
    ///
    /// - Returns: The currently selectable system video devices.
    func listCameraDevices() -> [CameraDevice] {
        cameraController.listCameraDevices()
    }

    /// The active local video track, or nil without a media source.
    var currentTrack: RealtimeVideoTrack? {
        guard let activeSource else {
            return nil
        }
        return currentTrack(for: activeSource.kind)
    }

    /// The local video format, or nil without an active track.
    var currentVideoFormat: RealtimeVideoFormat? {
        currentTrack?.videoFormat
    }

    var isExternalVideo: Bool {
        activeSource?.kind == .external
    }

    /// Whether the current source includes SDK-managed local audio.
    var hasAudio: Bool {
        switch activeSource?.kind {
        case .camera:
            return cameraController.useMicrophone
        default:
            return false
        }
    }

    /// Sets a one-time internal readiness handler for the current camera stream.
    ///
    /// - Parameter handler: Called after capture is ready and preview is bound; an empty value clears it.
    func setCameraPreviewReadyHandler(_ handler: CameraPreviewReadyHandler?) {
        cameraController.setPreviewReadyHandler(handler)
    }

    /// Starts receiving touch trajectories for the current generation task.
    ///
    /// - Parameters:
    ///   - taskID: The current generation task identifier.
    ///   - videoFormat: The local media output format.
    func startInteraction(
        taskID: String,
        videoFormat: RealtimeVideoFormat
    ) async {
        await interactionController.startInteraction(
            taskID: taskID,
            videoFormat: videoFormat
        )
    }

    /// Stops receiving trajectories and clears the current task.
    func stopInteraction() async {
        await interactionController.stopInteraction()
    }

    /// Submits a touch trajectory.
    ///
    /// - Parameter frame: The trajectory and display dimensions captured from the current view.
    func submitInteraction(_ frame: InteractionFrame) async {
        await interactionController.submitInteraction(frame)
    }

    /// Creates and retains a local camera stream, starting capture and local preview.
    ///
    /// - Parameters:
    ///   - videoFormat: The target camera capture video format.
    ///   - deviceID: The initial device identifier; an empty value uses the system default camera.
    ///   - useMicrophone: Whether to use the microphone; permission is checked at creation and capture starts on connection.
    /// - Returns: The media stream containing the local camera video track.
    /// - Throws: An error on camera permission, RTC initialization, or capture startup failure;
    ///   also fails if a media source is already active.
    func initializeRTC() async throws {
        try await rtcManager.initialize()
        hasPreparedRTC = true
    }

    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        useMicrophone: Bool = false,
        retainRTCOnFailure: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await createSource(kind: .camera, releaseRTCOnFailure: !retainRTCOnFailure) {
            try await self.cameraController.createLocalCameraStream(
                videoFormat: videoFormat,
                deviceID: deviceID,
                useMicrophone: useMicrophone
            )
        }
    }

    /// Binds caller-owned video input through the same ownership and RTC lifecycle as camera input.
    func createExternalVideoStream(
        source: any RealtimeExternalVideoSource,
        videoFormat: RealtimeVideoFormat?
    ) async throws -> RealtimeMediaStream {
        guard let externalController else {
            throw XmaxError(code: .invalidConfiguration, message: "External video input is unavailable")
        }
        return try await createSource(kind: .external) {
            try await externalController.create(source: source, videoFormat: videoFormat)
        }
    }

    /// Stops external frame delivery without taking ownership of caller capture resources.
    func stopExternalVideoStream() async {
        await stopSource(ifKindIs: .external)
    }

    /// Starts internal audio capture for a microphone-enabled camera stream; other sources are unaffected.
    ///
    /// - Throws: An error on cancellation or RTC audio capture startup failure.
    func startMicrophoneCapture() throws {
        try Task.checkCancellation()
        guard let activeSource, activeSource.kind == .camera else { return }
        guard captureStopOperation?.sourceID != activeSource.id else { throw CancellationError() }
        try cameraController.startMicrophoneCapture()
    }

    /// Stops microphone capture while retaining camera preview and microphone configuration.
    ///
    /// - Throws: An error if stopping RTC audio capture fails.
    func stopMicrophoneCapture() throws {
        guard activeSource?.kind == .camera else { return }
        try cameraController.stopMicrophoneCapture()
    }

    /// Stops camera capture immediately without waiting for creation or remote operations.
    func stopLocalCapture() async {
        guard let activeSource, activeSource.kind == .camera else { return }
        if let captureStopOperation, captureStopOperation.sourceID == activeSource.id {
            await captureStopOperation.task.value
            return
        }
        mediaOperation?.task.cancel()
        let task = Task { [cameraController] in
            await cameraController.stopLocalCameraStream()
        }
        captureStopOperation = LocalMediaStopOperation(id: UUID(), sourceID: activeSource.id, task: task)
        await task.value
    }

    /// Stops and releases the local camera stream, preview binding, and RTC resources;
    /// does nothing if the current source is not a camera.
    func stopLocalCameraStream() async {
        await stopSource(ifKindIs: .camera)
    }

    /// Stops and releases the local media stream, preview binding, and RTC engine;
    /// does nothing without an active source.
    func stopLocalStream() async {
        guard let activeSource else {
            // Parallel startup may have acquired an engine before a source was installed.
            if hasPreparedRTC {
                await rtcManager.destroy()
                hasPreparedRTC = false
            }
            return
        }
        await stopSource(ifKindIs: activeSource.kind)
    }

    /// Switches to the specified camera device while retaining the current video track.
    ///
    /// - Returns: The local media stream with the updated camera position.
    /// - Throws: An error if the current source is not a camera, another media operation exists, or switching fails.
    func switchCamera(to deviceID: String) async throws -> RealtimeMediaStream {
        guard activeSource?.kind == .camera else {
            throw XmaxError(
                code: .rtcError,
                message: "Local camera preview is not started"
            )
        }
        try ensureNoOperationInProgress()
        return try await cameraController.switchCamera(to: deviceID)
    }

    /// Checks whether the active media source owns the specified stream.
    ///
    /// - Parameter stream: The media stream whose ownership is being validated.
    /// - Returns: `true` if the active source owns the stream's video track;
    ///   otherwise returns `false`.
    func owns(_ stream: RealtimeMediaStream) -> Bool {
        guard let videoTrack = stream.videoTrack else {
            return false
        }
        return videoTrack === currentTrack
    }
}

private extension MediaController {
    /// Distinguishes the owned local media source.
    enum LocalMediaKind: Sendable {
        case camera
        case external
    }

    /// Identifies the active media source and its kind.
    final class ActiveLocalMediaSource {

        /// Source identity
        let id: UUID
        let kind: LocalMediaKind

        /// Records the current media source identity and kind.
        ///
        /// - Parameters:
        ///   - id: The unique source identifier.
        ///   - kind: The source kind.
        init(id: UUID, kind: LocalMediaKind) {
            self.id = id
            self.kind = kind
        }
    }

    /// Associates a media creation task with its source.
    struct LocalMediaOperation {

        /// Operation identity
        let id: UUID
        let sourceID: UUID

        /// Creation task
        let task: Task<RealtimeMediaStream, any Error>
    }

    /// Associates a media stop task with its source.
    struct LocalMediaStopOperation {

        /// Operation identity
        let id: UUID
        let sourceID: UUID

        /// Stop task
        let task: Task<Void, Never>
    }

    /// Acquires local media ownership and performs media creation.
    ///
    /// - Parameters:
    ///   - kind: The media source kind to create.
    ///   - body: The media creation operation executed after engine initialization.
    /// - Returns: The successfully created and still-valid local media stream.
    /// - Throws: An error on an existing source, engine initialization or media creation failure, or cancellation.
    func createSource(
        kind: LocalMediaKind,
        releaseRTCOnFailure: Bool = true,
        operation body: @escaping @Sendable () async throws ->
            RealtimeMediaStream
    ) async throws -> RealtimeMediaStream {
        guard activeSource == nil else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Stop the current local media stream before " +
                    "creating another one"
            )
        }

        let sourceID = UUID()
        captureStopOperation = nil
        activeSource = ActiveLocalMediaSource(id: sourceID, kind: kind)
        let needsRTCInitialization = !hasPreparedRTC
        let operation = makeMediaOperation(sourceID: sourceID) {
            if needsRTCInitialization {
                try await LocalMediaPreparationTiming.measureAsync(.engineAcquire) {
                    try await self.rtcManager.initialize()
                }
            }
            try Task.checkCancellation()
            return try await body()
        }
        mediaOperation = operation

        do {
            let stream = try await withTaskCancellationHandler {
                try await operation.task.value
            } onCancel: {
                operation.task.cancel()
            }
            try ensureCreationActive(sourceID: sourceID)
            clearMediaOperation(id: operation.id)
            return stream
        } catch {
            clearMediaOperation(id: operation.id)
            if releaseRTCOnFailure, activeSource?.id == sourceID,
               stopOperation?.sourceID != sourceID {
                await rtcManager.destroy()
                hasPreparedRTC = false
                activeSource = nil
            }
            throw XmaxError.from(error)
        }
    }

    /// Stops local media of the specified source kind.
    ///
    /// - Parameter kind: The media source kind to stop.
    func stopSource(ifKindIs kind: LocalMediaKind) async {
        guard let activeSource, activeSource.kind == kind else {
            return
        }
        let sourceID = activeSource.id
        if let stopOperation, stopOperation.sourceID == sourceID {
            await stopOperation.task.value
            return
        }

        let operationID = UUID()
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.performStop(
                sourceID: sourceID,
                operationID: operationID
            )
        }
        stopOperation = LocalMediaStopOperation(
            id: operationID,
            sourceID: sourceID,
            task: task
        )
        await task.value
    }

    /// Waits for media creation to finish, then releases the source and RTC engine.
    ///
    /// - Parameters:
    ///   - sourceID: The media source identifier to release.
    ///   - operationID: The current stop operation identifier.
    func performStop(
        sourceID: UUID,
        operationID: UUID
    ) async {
        if let mediaOperation,
           mediaOperation.sourceID == sourceID {
            do {
                _ = try await mediaOperation.task.value
            } catch {
                if !Self.isCancelled(error) {
                    XmaxLogger.realtime.error(
                        message: "等待本地媒体操作结束失败 " +
                            "(Failed to Await Local Media Operation Completion)\n" +
                            "└─ \(XmaxLogger.localized("原因：", "Reason: "))" +
                            (error as NSError).localizedDescription
                    )
                }
            }
        }

        if let activeSource, activeSource.id == sourceID {
            await stopSource(kind: activeSource.kind)
            await rtcManager.destroy()
            hasPreparedRTC = false
            self.activeSource = nil
        }
        if stopOperation?.id == operationID {
            stopOperation = nil
        }
    }

    /// Stops local media of the specified source kind.
    ///
    /// - Parameter kind: The media source kind to stop.
    func stopSource(kind: LocalMediaKind) async {
        switch kind {
        case .camera:
            await stopLocalCapture()
        case .external:
            await externalController?.stop()
        }
    }

    /// Gets the video track owned by the specified source kind.
    ///
    /// - Parameter kind: The local media source kind.
    /// - Returns: The component's video track; `nil` before creation.
    func currentTrack(for kind: LocalMediaKind) -> RealtimeVideoTrack? {
        switch kind {
        case .camera:
            cameraController.currentTrack
        case .external:
            externalController?.currentTrack
        }
    }

    /// Creates an asynchronous operation associated with a media source.
    ///
    /// - Parameters:
    ///   - sourceID: The operation's media source identifier.
    ///   - operation: The asynchronous local stream creation operation.
    /// - Returns: The media operation containing a unique identifier and task.
    func makeMediaOperation(
        sourceID: UUID,
        operation: @escaping @Sendable () async throws -> RealtimeMediaStream
    ) -> LocalMediaOperation {
        LocalMediaOperation(
            id: UUID(),
            sourceID: sourceID,
            task: Task(operation: operation)
        )
    }

    /// Validates that the creation result belongs to the active source.
    ///
    /// - Parameter sourceID: The source identifier for media creation.
    /// - Throws: Cancellation if the source is invalid or stopping.
    func ensureCreationActive(sourceID: UUID) throws {
        guard activeSource?.id == sourceID,
              stopOperation?.sourceID != sourceID,
              captureStopOperation?.sourceID != sourceID else {
            throw XmaxError(
                code: .cancelled,
                message: "Local media stream creation was cancelled"
            )
        }
    }

    /// Checks that no media creation or stop operation exists.
    ///
    /// - Throws: An error if a media operation remains unfinished.
    func ensureNoOperationInProgress() throws {
        let captureIsStopping = activeSource.map { captureStopOperation?.sourceID == $0.id } ?? false
        guard mediaOperation == nil, stopOperation == nil,
              !captureIsStopping else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Another local media operation is already in progress"
            )
        }
    }

    /// Clears the matching media creation operation.
    ///
    /// - Parameter id: The operation identifier to clear.
    func clearMediaOperation(id: UUID) {
        if mediaOperation?.id == id {
            mediaOperation = nil
        }
    }

    /// Checks whether an error is an SDK operation cancellation.
    ///
    /// - Parameter error: The error to check.
    /// - Returns: `true` if the SDK error code is cancellation.
    static func isCancelled(_ error: any Error) -> Bool {
        (error as? XmaxError)?.code == .cancelled
    }
}

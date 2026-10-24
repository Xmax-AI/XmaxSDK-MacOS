//
//  StreamController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Updates remote result bindings on the main thread; nil clears the binding.
typealias RemoteStreamListener =
    @MainActor @Sendable (
        RemoteStream?
    ) throws -> Void

/// Coordinates RTC rooms, media streams, encoding, and quality events.
final class StreamController: StreamControlling, RtcEventListener,
    @unchecked Sendable
{

    /// The RTC media publication, subscription, and frame adapter.
    private let rtcManager: any RtcManaging

    /// The room connection and signaling controller.
    private let roomController: any RoomControlling

    /// The uplink encoder configuration controller.
    private let encodingController: any EncodingControlling

    /// The quality statistics and adaptation controller.
    private let qualityController: any QualityControlling

    /// The transport failure handler.
    private let errorListener: XmaxErrorListener

    /// The remote result publication and end handler.
    private let remoteStreamListener: RemoteStreamListener

    /// The generation stream confirmation timeout.
    private let generationTiming: StreamGenerationTiming

    /// The connection and generation startup timing recorder.
    private let timing: RealtimeTiming

    /// The remote volume percentage, from 0 to 100.
    private var remoteAudioVolumePercentage = 100

    /// The lock protecting connection, media, and generation state.
    private let stateLock = NSLock()

    /// The lock serializing media and generation operations.
    private let operationLock = NSRecursiveLock()

    /// The transport state snapshot.
    private var state = State()

    /// Whether a generation task remains active.
    var hasGenerationTask: Bool {
        stateLock.withLock { state.generationTask != nil }
    }

    /// The remote playback volume, from 0 to 1.
    var remoteAudioVolume: Float {
        Float(stateLock.withLock { remoteAudioVolumePercentage }) / 100
    }

    /// Creates a stream controller from room, encoding, and quality components.
    ///
    /// - Parameters:
    ///   - rtcManager: The underlying RTC manager.
    ///   - errorListener: The callback receiving stream runtime errors.
    ///   - remoteStreamListener: The callback receiving remote result stream binding changes.
    ///   - generationTiming: The result stream confirmation timeout configuration.
    ///   - timing: The shared realtime startup timing recorder.
    convenience init(
        rtcManager: any RtcManaging,
        errorListener: @escaping XmaxErrorListener = { _ in },
        remoteStreamListener: @escaping RemoteStreamListener = { _ in },
        generationTiming: StreamGenerationTiming = .live,
        timing: RealtimeTiming = RealtimeTiming()
    ) {
        self.init(
            rtcManager: rtcManager,
            roomController: RoomController(
                rtcManager: rtcManager,
                timing: timing
            ),
            encodingController: EncodingController(rtcManager: rtcManager),
            qualityController: QualityController(rtcManager: rtcManager),
            errorListener: errorListener,
            remoteStreamListener: remoteStreamListener,
            generationTiming: generationTiming,
            timing: timing
        )
    }

    /// Creates a stream controller with specified components and registers RTC event listeners.
    ///
    /// - Parameters:
    ///   - rtcManager: The underlying RTC manager.
    ///   - roomController: The room connection and signaling component.
    ///   - encodingController: The video encoding configuration component.
    ///   - qualityController: The network quality and tier adjustment component.
    ///   - errorListener: The callback receiving stream runtime errors.
    ///   - remoteStreamListener: The callback receiving remote result stream binding changes.
    ///   - generationTiming: The result stream confirmation timeout configuration.
    ///   - timing: The shared realtime startup timing recorder.
    init(
        rtcManager: any RtcManaging,
        roomController: any RoomControlling,
        encodingController: any EncodingControlling,
        qualityController: any QualityControlling,
        errorListener: @escaping XmaxErrorListener = { _ in },
        remoteStreamListener: @escaping RemoteStreamListener = { _ in },
        generationTiming: StreamGenerationTiming = .live,
        timing: RealtimeTiming = RealtimeTiming()
    ) {
        self.rtcManager = rtcManager
        self.roomController = roomController
        self.encodingController = encodingController
        self.qualityController = qualityController
        self.errorListener = errorListener
        self.remoteStreamListener = remoteStreamListener
        self.generationTiming = generationTiming
        self.timing = timing
        rtcManager.setEventListener(self)
    }

    /// Sets realtime video encoder configuration.
    ///
    /// - Parameter videoFormat: The width, height, and frame rate for RTC encoding.
    ///
    /// - Throws: An error on invalid video format or RTC encoding configuration failure.
    func setVideoEncoderConfig(
        _ videoFormat: RealtimeVideoFormat
    ) throws {
        try encodingController.configure(videoFormat)
    }

    /// The current media baseline and directional quality levels.
    var qualityConfiguration: QualityConfiguration? { qualityController.qualityConfiguration }

    /// Prepares upstream and downstream tiers from media baseline and model history.
    ///
    /// - Parameters:
    ///   - baseline: The original local media output format, unchanged by tier adjustments.
    ///   - model: The model identifier isolating tier history.
    ///
    /// - Returns: The initial upstream and downstream configuration for this connection.
    func prepareQuality(
        baseline: RealtimeVideoFormat,
        model: String
    ) -> QualityConfiguration {
        qualityController.prepareQuality(
            baseline: baseline,
            model: model
        )
    }

    /// Sets the internal tier adjustment callback without affecting public network quality observation.
    ///
    /// - Parameter listener: Receives network quality and monotonic sample time; nil removes it.
    func setAdaptiveQualityListener(
        _ listener: (@Sendable (RealtimeNetworkQuality, TimeInterval) -> Void)?
    ) {
        qualityController.setAdaptiveQualityListener(listener)
    }

    /// Consumes the current network sample and returns candidate tiers.
    ///
    /// - Parameters:
    ///   - quality: The current upstream and downstream network quality.
    ///   - sampledAt: The monotonic sample time in seconds.
    ///
    /// - Returns: The candidate tiers meeting consecutive sample and cooldown requirements.
    func proposeQuality(
        _ quality: RealtimeNetworkQuality,
        sampledAt: TimeInterval
    ) -> QualityChange {
        qualityController.proposeQuality(
            quality,
            sampledAt: sampledAt
        )
    }

    /// Commits tier adjustment results and saves history on success.
    ///
    /// - Parameters:
    ///   - downlink: true indicates downstream; false indicates upstream.
    ///   - level: The attempted tier in 1...5.
    ///   - success: Whether configuration applied successfully.
    func completeQuality(
        downlink: Bool,
        level: Int,
        success: Bool
    ) {
        qualityController.completeQuality(
            downlink: downlink,
            level: level,
            success: success
        )
    }

    /// Clears the consecutive sampling window.
    func resetQualitySamples() { qualityController.resetQualitySamples() }

    /// Sets the upstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil before publication or after disconnect. Pass nil to
    ///   clear it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    ) {
        qualityController.setUplinkVideoStatisticsListener(listener)
    }

    /// Sets the downstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil when the result stream is cleared. Pass nil to
    ///   clear it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    ) {
        qualityController.setDownlinkVideoStatisticsListener(listener)
    }

    /// Sets the network quality listener; nil clears it.
    ///
    /// - Parameter listener: The listener receiving upstream and downstream quality events;
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    ) {
        qualityController.setNetworkQualityListener(listener)
    }

    /// Sets the device performance alarm listener; nil clears it.
    ///
    /// - Parameter listener: The listener receiving device performance limitation and recovery events;
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    ) {
        qualityController.setPerformanceAlarmListener(listener)
    }

    /// Sets the playback volume for remote generated audio.
    ///
    /// - Parameter volume: The validated volume in `0...1`.
    ///
    /// - Throws: An error if RTC volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Float
    ) throws {
        let rtcVolume = Int((volume * 100).rounded())
        try operationLock.withLock {
            let userIDs = stateLock.withLock {
                state.subscribedRemoteAudioUserIDs.sorted()
            }
            for userID in userIDs {
                try rtcManager.setRemoteAudioVolume(
                    rtcVolume,
                    for: userID
                )
            }
            stateLock.withLock {
                remoteAudioVolumePercentage = rtcVolume
            }
        }
    }

    /// Joins an RTC room and publishes local media.
    ///
    /// - Parameters:
    ///   - connection: The RTC room, user, token, and target bot information.
    ///   - includeLocalAudio: Whether to publish local audio alongside video.
    ///   - ensureActive: The callback validating connection operation identity across asynchronous boundaries;
    ///
    /// - Throws: An error on connection cancellation or RTC join, room configuration, or local publication
    ///   failure.
    func connect(
        connection: RealtimeSessionConnection,
        includeLocalAudio: Bool,
        beforePublication: @escaping @Sendable () async throws -> Void = {},
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws {
        try ensureActive()
        try configureRoom(
            roomID: connection.roomID,
            botName: connection.botName
        )
        try await roomController.join(
            connection: connection,
            ensureActive: ensureActive
        )
        try await beforePublication()
        try ensureActive()
        timing.beginLocalPublication()
        try publishLocalStream(includeAudio: includeLocalAudio)
        timing.finishLocalPublication()
    }

    /// Clears generation, local publication, and remote subscription state, then leaves the RTC room;
    /// returns safely without an active room.
    func disconnect() async {
        qualityController.resetQuality()
        await resetStream()
        await roomController.leave()
    }

    /// Creates a generation task, sends its start signal, and begins result confirmation.
    ///
    /// - Parameters:
    ///   - taskID: The unique generation task identifier.
    ///   - videoFormat: The server generation video format.
    ///   - targetSize: The returned pixel dimensions; `nil` preserves generation dimensions.
    ///   - context: The generation conditions, including reference image and prompt.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve source aspect ratio and pad the canvas using contain mode.
    ///
    /// - Returns: The task awaiting remote result stream publication confirmation.
    ///
    /// - Throws: An error on invalid task parameters, unready room, existing generation task, signal failure, or send
    ///   timeout.
    func beginGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false
    ) async throws -> Task<Void, any Error> {
        timing.beginSignal(taskID: taskID)
        let confirmation = try beginGenerationConfirmation(taskID: taskID)
        do {
            try await roomController.startGeneration(
                taskID: taskID,
                videoFormat: videoFormat,
                targetSize: targetSize,
                context: context,
                faceRestoration: faceRestoration,
                paddingContain: paddingContain
            )
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.rtcManager.awaitPendingMessages() }
                group.addTask {
                    try await Task.sleep(nanoseconds: self.generationTiming.timeoutNanoseconds)
                    throw XmaxError(
                        code: .timeout,
                        message: "Realtime generation start timed out"
                    )
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            try Task.checkCancellation()
            await confirmPublishedRemoteStream(taskID: taskID)
            return confirmation
        } catch {
            confirmation.cancel()
            try? await stopGeneration(taskID: taskID)
            throw XmaxError.from(error)
        }
    }

    /// Subscribes to generation audio after the first remote frame becomes displayable.
    ///
    /// - Throws: An error if the result stream is unconfirmed or RTC volume or subscription configuration fails.
    func activateRemoteAudio() throws {
        try operationLock.withLock {
            let remoteStream: RemoteStream? = stateLock.withLock {
                guard state.generationTask != nil else { return nil }
                return state.activeRemoteStream
            }
            guard let remoteStream else {
                throw XmaxError(
                    code: .rtcError,
                    message: "Remote generation audio stream is unavailable"
                )
            }
            try subscribeRemoteAudio(userID: remoteStream.userID)
        }
    }

    /// Sends condition updates for the current generation task.
    ///
    /// - Parameters:
    ///   - taskID: The unique generation task identifier.
    ///   - videoFormat: The server generation video format.
    ///   - targetSize: The returned pixel dimensions; `nil` preserves generation dimensions.
    ///   - context: The generation conditions, including reference image and prompt.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve source aspect ratio and pad the canvas using contain mode.
    ///
    /// - Throws: An error on unready room, invalid parameters, or signal submission failure.
    func updateGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false
    ) async throws {
        try await roomController.changeGenerationCondition(
            taskID: taskID,
            videoFormat: videoFormat,
            targetSize: targetSize,
            context: context,
            faceRestoration: faceRestoration,
            paddingContain: paddingContain
        )
    }

    /// Stops generation and clears the remote result stream.
    ///
    /// - Parameter taskID: The generation task identifier to stop; an empty string stops
    ///
    /// - Throws: An error if sending the RTC stop signal fails.
    func stopGeneration(
        taskID: String
    ) async throws {
        let stoppedTaskID = await stopStreamGeneration(taskID: taskID)
        guard taskID.isEmpty || !stoppedTaskID.isEmpty else {
            return
        }
        try await roomController.stopGeneration(taskID: stoppedTaskID)
    }

    /// Sends a generation task's interaction trajectory.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier receiving the trajectory.
    ///   - points: The trajectory points to send; empty arrays are ignored.
    ///
    /// - Throws: An error on unready RTC room, invalid task identity, or trajectory signal
    ///   failure.
    func sendTracks(
        taskID: String,
        points: [RealtimePoint]
    ) async throws {
        try await roomController.sendTracks(
            taskID: taskID,
            points: points
        )
    }

    /// Validates and records the room and target bot identifiers.
    ///
    /// - Parameters:
    ///   - roomID: The RTC room identifier.
    ///   - botName: The target bot account; `nil` or empty permits any account.
    ///
    /// - Throws: An error if the room identifier is empty or media state remains active.
    func configureRoom(
        roomID: String,
        botName: String?
    ) throws {
        let roomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let botName =
            botName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !roomID.isEmpty else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "RTC room ID cannot be empty"
            )
        }

        try operationLock.withLock {
            try stateLock.withLock {
                guard !state.localVideoPublished,
                    !state.localAudioPublished,
                    state.subscribedRemoteUserIDs.isEmpty,
                    state.generationTask == nil
                else {
                    throw XmaxError(
                        code: .invalidConfiguration,
                        message: "Reset the current RTC room before " + "configuring another one"
                    )
                }
                state.roomID = roomID
                state.botName = botName
            }
        }
    }

    /// Publishes local video and configured local audio.
    ///
    /// - Parameter includeAudio: Whether to also publish local audio.
    ///
    /// - Throws: An error if the room is unconfigured or RTC media publication fails.
    func publishLocalStream(
        includeAudio: Bool
    ) throws {
        try operationLock.withLock {
            let currentState = stateLock.withLock { state }
            guard !currentState.roomID.isEmpty else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Configure an RTC room before publishing " + "the local stream"
                )
            }

            var publishedVideoInOperation = false
            do {
                if !currentState.localVideoPublished {
                    try rtcManager.publishLocalVideo()
                    stateLock.withLock {
                        state.localVideoPublished = true
                    }
                    qualityController.setUplinkVideoStatisticsEnabled(true)
                    publishedVideoInOperation = true
                }

                if includeAudio && !currentState.localAudioPublished {
                    try rtcManager.publishLocalAudio()
                    stateLock.withLock {
                        state.localAudioPublished = true
                    }
                }
            } catch {
                if publishedVideoInOperation {
                    rollbackLocalVideoPublication()
                }
                throw XmaxError.from(error)
            }
        }
    }

    /// Pushes local external video during an active generation task; ignores frames otherwise.
    ///
    /// - Parameter frame: The local video frame prepared for RTC.
    ///
    /// - Throws: An error if RTC resources are unready or frame conversion fails.
    func pushLocalVideoFrame(
        _ frame: VideoFrame
    ) throws {
        guard stateLock.withLock({ state.generationTask != nil }) else {
            return
        }
        do {
            try rtcManager.pushExternalVideoFrame(frame)
        } catch {
            throw XmaxError.from(error)
        }
    }

    /// Pushes a local external audio frame.
    ///
    /// - Parameter frame: The PCM frame prepared for RTC;
    ///
    /// - Throws: An error if RTC resources are unready or audio frame conversion fails.
    func pushLocalAudioFrame(
        _ frame: AudioFrame
    ) throws {
        guard stateLock.withLock({ state.localAudioPublished }) else {
            return
        }
        do {
            try rtcManager.pushExternalAudioFrame(frame)
        } catch {
            throw XmaxError.from(error)
        }
    }

    /// Adjusts return dimensions without restarting generation.
    ///
    /// - Parameters:
    ///   - taskID: The current generation task identifier.
    ///   - targetSize: The returned integer-pixel dimensions.
    ///   - ensureActive: Checks current configuration operation validity before sending.
    ///
    /// - Throws: An error on cancellation, unready room, or signal send failure.
    func changeTargetSize(
        taskID: String,
        targetSize: CGSize,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws {
        try await roomController.changeTargetSize(
            taskID: taskID,
            targetSize: targetSize,
            ensureActive: ensureActive
        )
    }

    /// Creates a generation result confirmation wait and its timeout task.
    ///
    /// - Parameter taskID: The generation task identifier to confirm.
    ///
    /// - Returns: The cancellable result confirmation task.
    ///
    /// - Throws: An error on invalid task identity, unconfigured room, existing task, or waiter creation failure.
    func beginGenerationConfirmation(
        taskID: String
    ) throws -> Task<Void, any Error> {
        let taskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Realtime generation task ID cannot be empty"
            )
        }

        return try operationLock.withLock {
            let currentState = stateLock.withLock { state }
            guard !currentState.roomID.isEmpty else {
                throw XmaxError(
                    code: .rtcError,
                    message: "RTC room is not configured"
                )
            }
            guard currentState.generationTask == nil else {
                throw XmaxError(
                    code: .rtcError,
                    message: "Realtime generation is already active"
                )
            }

            var continuation: AsyncThrowingStream<Void, any Error>.Continuation?
            let stream = AsyncThrowingStream<Void, any Error> {
                continuation = $0
            }
            guard let continuation else {
                throw XmaxError(
                    code: .internalError,
                    message: "Failed to create generation confirmation"
                )
            }
            let waiter = GenerationWaiter(
                taskID: taskID,
                continuation: continuation
            )
            stateLock.withLock {
                state.generationTask = GenerationTask(id: taskID)
                state.generationWaiter = waiter
            }
            waiter.timeoutTask = Task { [weak self, weak waiter] in
                guard let self, let waiter else {
                    return
                }
                do {
                    try await Task.sleep(
                        nanoseconds: self.generationTiming.timeoutNanoseconds
                    )
                } catch {
                    return
                }
                self.rejectGenerationStart(
                    taskID: waiter.taskID,
                    error: XmaxError(
                        code: .timeout,
                        message: "Realtime generation start timed out"
                    )
                )
            }

            return Task { [weak self] in
                try await withTaskCancellationHandler {
                    for try await _ in stream {
                        return
                    }
                } onCancel: {
                    self?.rejectGenerationStart(
                        taskID: taskID,
                        error: XmaxError(
                            code: .cancelled,
                            message: "Realtime generation start cancelled"
                        )
                    )
                }
            }
        }
    }

    /// Stops the matching generation task and clears remote audio and result bindings.
    ///
    /// - Parameters:
    ///   - taskID: The task identifier to stop; an empty string indicates the current task.
    ///   - reason: The cancellation reason ending confirmation waiting.
    ///
    /// - Returns: The stopped task identifier; an empty string if none matches.
    @discardableResult
    func stopStreamGeneration(
        taskID: String,
        reason: String = "Realtime generation start cancelled"
    ) async -> String {
        let result = operationLock.withLock { () -> StopResult? in
            let currentTaskID = stateLock.withLock {
                state.generationTask?.id ?? ""
            }
            guard taskID.isEmpty || taskID == currentTaskID else {
                return nil
            }

            let stoppedState = stateLock.withLock {
                () -> (
                    GenerationWaiter?,
                    Set<String>
                ) in
                let waiter = state.generationWaiter
                let remoteAudioUserIDs =
                    state.subscribedRemoteAudioUserIDs
                state.generationTask = nil
                state.generationWaiter = nil
                state.activeRemoteStream = nil
                state.subscribedRemoteAudioUserIDs.removeAll()
                return (waiter, remoteAudioUserIDs)
            }
            return StopResult(
                taskID: currentTaskID,
                waiter: stoppedState.0,
                remoteAudioUserIDs: stoppedState.1
            )
        }
        guard let result else {
            return ""
        }

        reject(
            result.waiter,
            error: XmaxError(
                code: .cancelled,
                message: reason
            )
        )
        for userID in result.remoteAudioUserIDs.sorted() {
            performCleanup("取消订阅 RTC 远端音频失败 (Failed to Unsubscribe from RTC Remote Audio)") {
                try rtcManager.subscribeRemoteAudio(
                    userID: userID,
                    subscribe: false
                )
            }
        }
        await clearRemoteStream()
        return result.taskID
    }

    /// Clears generation, publication, and subscription state and releases corresponding RTC resources.
    func resetStream() async {
        qualityController.setUplinkVideoStatisticsEnabled(false)
        _ = await stopStreamGeneration(taskID: "")
        operationLock.withLock {
            let previousState = stateLock.withLock { () -> State in
                let previousState = state
                state = State()
                return previousState
            }

            for userID in previousState.subscribedRemoteUserIDs.sorted() {
                performCleanup("取消订阅 RTC 远端视频失败 (Failed to Unsubscribe from RTC Remote Video)") {
                    try rtcManager.subscribeRemoteVideo(
                        userID: userID,
                        subscribe: false
                    )
                }
            }
            if previousState.localAudioPublished {
                performCleanup("取消发布 RTC 本地音频失败 (Failed to Unpublish RTC Local Audio)") {
                    try rtcManager.unpublishLocalAudio()
                }
            }
            if previousState.localVideoPublished {
                performCleanup("取消发布 RTC 本地视频失败 (Failed to Unpublish RTC Local Video)") {
                    try rtcManager.unpublishLocalVideo()
                }
            }
        }
    }

    /// Receives remote user video publication state changes.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - published: Whether video is currently published.
    @MainActor
    func onRemoteVideoPublished(
        userID: String,
        published: Bool
    ) {
        let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty else {
            return
        }

        operationLock.withLock {
            let currentState = stateLock.withLock { state }
            guard !currentState.roomID.isEmpty,
                currentState.botName.isEmpty || currentState.botName == userID
            else {
                return
            }

            if published {
                subscribeRemoteVideo(userID: userID)
                confirmRemoteStream(
                    RemoteStream(
                        roomID: currentState.roomID,
                        userID: userID
                    )
                )
            } else {
                _ = stateLock.withLock {
                    state.subscribedRemoteUserIDs.remove(userID)
                }
                if currentState.activeRemoteStream?.userID == userID {
                    unsubscribeRemoteAudio(userID: userID)
                    stateLock.withLock {
                        state.activeRemoteStream = nil
                    }
                    clearRemoteStream()
                }
            }
        }
    }

    /// Receives errors preventing the RTC connection or signaling transport from continuing.
    ///
    /// - Parameter error: The connection or signaling transport error.
    @MainActor
    func onRtcFailure(
        _ error: XmaxError
    ) {
        let taskID = stateLock.withLock { state.generationWaiter?.taskID }
        if let taskID {
            rejectGenerationStart(
                taskID: taskID,
                error: error
            )
        } else {
            errorListener(error)
        }
    }
}

private extension StreamController {

    /// Marks the start signal as sent and confirms the published target result stream.
    ///
    /// - Parameter taskID: The generation task identifier associated with the start signal.
    @MainActor
    func confirmPublishedRemoteStream(
        taskID: String
    ) {
        let stream = stateLock.withLock { () -> RemoteStream? in
            guard let waiter = state.generationWaiter, waiter.taskID == taskID else { return nil }
            waiter.signalSent = true
            guard
                let userID = state.subscribedRemoteUserIDs.first(where: {
                    state.botName.isEmpty || $0 == state.botName
                })
            else { return nil }
            return RemoteStream(
                roomID: state.roomID,
                userID: userID
            )
        }
        if let stream { confirmRemoteStream(stream) }
    }

    /// Binds the published target result stream and completes generation confirmation.
    ///
    /// - Parameter stream: The remote result stream to confirm.
    @MainActor
    func confirmRemoteStream(
        _ stream: RemoteStream
    ) {
        let waiter = operationLock.withLock { () -> GenerationWaiter? in
            stateLock.withLock {
                guard state.generationTask != nil,
                    let waiter = state.generationWaiter,
                    waiter.signalSent,
                    !waiter.confirmationPending,
                    state.subscribedRemoteUserIDs.contains(stream.userID),
                    stream.roomID == state.roomID,
                    state.botName.isEmpty || stream.userID == state.botName
                else {
                    return nil
                }
                waiter.confirmationPending = true
                return waiter
            }
        }
        guard let waiter else {
            return
        }
        do {
            try remoteStreamListener(stream)
            stateLock.withLock {
                if state.generationTask?.id == waiter.taskID {
                    state.activeRemoteStream = stream
                    qualityController.setDownlinkVideoStatisticsUser(stream.userID)
                }
            }
        } catch {
            rejectGenerationStart(
                taskID: waiter.taskID,
                error: XmaxError.from(error)
            )
            return
        }

        resolveGenerationStart(taskID: waiter.taskID)
    }
}

private extension StreamController {

    /// Stores media publication, subscription, and generation state for the current room.
    struct State {

        /// The current RTC room identifier.
        var roomID = ""

        /// The server-assigned result user identifier.
        var botName = ""

        /// Whether local video is published.
        var localVideoPublished = false

        /// Whether local audio is published.
        var localAudioPublished = false

        /// The remote users with subscribed video.
        var subscribedRemoteUserIDs: Set<String> = []

        /// The remote users with subscribed audio.
        var subscribedRemoteAudioUserIDs: Set<String> = []

        /// The submitted generation task.
        var generationTask: GenerationTask?

        /// The waiter for generation signaling and remote stream readiness.
        var generationWaiter: GenerationWaiter?

        /// The confirmed remote result stream.
        var activeRemoteStream: RemoteStream?
    }

    /// Identifies the active generation task.
    struct GenerationTask {

        /// The unique generation task identifier.
        let id: String
    }

    /// Manages result stream confirmation, timeouts, and asynchronous notifications.
    final class GenerationWaiter: @unchecked Sendable {

        /// The generation task awaiting its result stream.
        let taskID: String

        /// The continuation completing confirmation.
        let continuation: AsyncThrowingStream<Void, any Error>.Continuation

        /// The generation result timeout task.
        var timeoutTask: Task<Void, Never>?

        /// Whether a matching result stream is being confirmed.
        var confirmationPending = false

        /// Whether start signaling was submitted successfully.
        var signalSent = false

        /// Creates a generation result confirmation context.
        init(
            taskID: String,
            continuation:
                AsyncThrowingStream<Void, any Error>.Continuation
        ) {
            self.taskID = taskID
            self.continuation = continuation
        }
    }

    /// Stores waiters and audio subscriptions requiring cleanup after generation stops.
    struct StopResult {

        /// The generation task to stop.
        let taskID: String

        /// The generation waiter to finish during cleanup.
        let waiter: GenerationWaiter?

        /// The remote audio subscriptions to cancel.
        let remoteAudioUserIDs: Set<String>
    }

    /// Subscribes to remote video and reports failures to the startup waiter or error callback.
    ///
    /// - Parameter userID: The remote user account to subscribe to.
    func subscribeRemoteVideo(
        userID: String
    ) {
        let alreadySubscribed = stateLock.withLock {
            state.subscribedRemoteUserIDs.contains(userID)
        }
        guard !alreadySubscribed else {
            return
        }

        do {
            try rtcManager.subscribeRemoteVideo(
                userID: userID,
                subscribe: true
            )
            _ = stateLock.withLock {
                state.subscribedRemoteUserIDs.insert(userID)
            }
        } catch {
            let xmaxError = XmaxError.from(error)
            let pendingTaskID = stateLock.withLock {
                state.generationWaiter == nil
                    ? nil
                    : state.generationTask?.id
            }
            if let pendingTaskID {
                rejectGenerationStart(
                    taskID: pendingTaskID,
                    error: xmaxError
                )
            } else {
                errorListener(xmaxError)
            }
        }
    }

    /// Applies the current volume before subscribing to remote audio.
    ///
    /// - Parameter userID: The remote user account to subscribe to.
    ///
    /// - Throws: An error on volume or audio subscription configuration failure.
    func subscribeRemoteAudio(
        userID: String
    ) throws {
        let audioState = stateLock.withLock {
            (
                state.subscribedRemoteAudioUserIDs.contains(userID),
                remoteAudioVolumePercentage
            )
        }
        guard !audioState.0 else {
            return
        }

        try rtcManager.setRemoteAudioVolume(
            audioState.1,
            for: userID
        )
        try rtcManager.subscribeRemoteAudio(
            userID: userID,
            subscribe: true
        )
        _ = stateLock.withLock {
            state.subscribedRemoteAudioUserIDs.insert(userID)
        }
    }

    /// Cancels the recorded remote audio subscription.
    ///
    /// - Parameter userID: The remote user account to unsubscribe from.
    func unsubscribeRemoteAudio(
        userID: String
    ) {
        let wasSubscribed = stateLock.withLock {
            state.subscribedRemoteAudioUserIDs.remove(userID) != nil
        }
        guard wasSubscribed else {
            return
        }
        performCleanup("取消订阅 RTC 远端音频失败 (Failed to Unsubscribe from RTC Remote Audio)") {
            try rtcManager.subscribeRemoteAudio(
                userID: userID,
                subscribe: false
            )
        }
    }

    /// Successfully completes result confirmation for the matching task.
    ///
    /// - Parameter taskID: The generation task identifier whose result stream is confirmed.
    func resolveGenerationStart(
        taskID: String
    ) {
        let waiter = operationLock.withLock { () -> GenerationWaiter? in
            stateLock.withLock {
                guard state.generationTask?.id == taskID,
                    state.generationWaiter?.taskID == taskID
                else {
                    return nil
                }
                let waiter = state.generationWaiter
                state.generationWaiter = nil
                return waiter
            }
        }
        guard let waiter else {
            return
        }
        waiter.timeoutTask?.cancel()
        waiter.continuation.yield()
        waiter.continuation.finish()
    }

    /// Fails result confirmation for the matching generation task.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier whose wait failed.
    ///   - error: The confirmation failure reason.
    func rejectGenerationStart(
        taskID: String,
        error: XmaxError
    ) {
        let waiter = operationLock.withLock { () -> GenerationWaiter? in
            stateLock.withLock {
                guard state.generationTask?.id == taskID,
                    state.generationWaiter?.taskID == taskID
                else {
                    return nil
                }
                let waiter = state.generationWaiter
                state.generationWaiter = nil
                return waiter
            }
        }
        reject(
            waiter,
            error: error
        )
    }

    /// Cancels the timeout and fails the specified waiter.
    ///
    /// - Parameters:
    ///   - waiter: The confirmation waiter to finish; `nil` does nothing.
    ///   - error: The error returned to the waiter.
    func reject(
        _ waiter: GenerationWaiter?,
        error: XmaxError
    ) {
        guard let waiter else {
            return
        }
        waiter.timeoutTask?.cancel()
        waiter.continuation.finish(throwing: error)
    }

    /// Clears the downstream statistics target and reports result stream unbinding.
    @MainActor
    func clearRemoteStream() {
        qualityController.setDownlinkVideoStatisticsUser(nil)
        do {
            try remoteStreamListener(nil)
        } catch {
            XmaxLogger.stream.error(
                message: "清理 RTC 远端生成流失败 (Failed to Clean Up RTC Remote Generation Stream)\n"
                    + "└─ \(XmaxLogger.localized("原因：", "Reason: "))" + (error as NSError).localizedDescription
            )
        }
    }

    /// Unpublishes video published by this operation and disables upstream statistics.
    func rollbackLocalVideoPublication() {
        qualityController.setUplinkVideoStatisticsEnabled(false)
        do {
            try rtcManager.unpublishLocalVideo()
            stateLock.withLock {
                state.localVideoPublished = false
            }
        } catch {
            XmaxLogger.stream.error(
                message: "回滚 RTC 本地视频发布失败 (Failed to Roll Back RTC Local Video Publication)\n"
                    + "└─ \(XmaxLogger.localized("原因：", "Reason: "))" + (error as NSError).localizedDescription
            )
        }
    }

    /// Performs cleanup and logs any failures.
    ///
    /// - Parameters:
    ///   - title: The Chinese and English titles for cleanup failure logs.
    ///   - action: The synchronous cleanup operation to perform.
    func performCleanup(
        _ title: String,
        action: () throws -> Void
    ) {
        do {
            try action()
        } catch {
            XmaxLogger.stream.error(
                message: "\(title)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))"
                    + (error as NSError).localizedDescription
            )
        }
    }
}

/// Defines the generation confirmation timeout.
struct StreamGenerationTiming: Sendable {

    /// The result stream confirmation timeout, in nanoseconds.
    let timeoutNanoseconds: UInt64

    /// The default result confirmation timeout.
    static let live = StreamGenerationTiming(
        timeoutNanoseconds: 30_000_000_000
    )
}

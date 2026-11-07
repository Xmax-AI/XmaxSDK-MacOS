//
//  XmaxRealtimeManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Manages realtime generation and its media session.
actor XmaxRealtimeManager: XmaxRealtimeManaging {

    /// The initial realtime configuration.
    nonisolated let configuration: RealtimeConfiguration

    // MARK: - Dependencies

    /// Coordinates realtime operations and cleanup.
    private let lifecycleManager: XmaxRealtimeLifecycleManager

    /// Manages the realtime connection.
    private let connectionManager: XmaxRealtimeConnectionManager

    /// Manages generation tasks.
    private let generationManager: XmaxRealtimeGenerationManager

    /// Reports failures and routes them to the affected operation.
    private let errorManager: XmaxRealtimeErrorManager

    /// Manages local media and interaction.
    private let mediaController: any MediaControlling

    /// Manages remote video rendering.
    private let renderController: any RenderControlling

    /// Manages RTC streams and signaling.
    private let streamController: any StreamControlling

    /// Resolves media dimensions for the model.
    private let mediaService: any MediaServicing

    /// Measures realtime startup.
    private let timing: RealtimeTiming

    /// Whether an adaptive quality request is already pending.
    private var qualityPending = false

    /// The current realtime connection and generation state.
    var currentState: RealtimeState {
        get async {
            await lifecycleManager.currentState
        }
    }

    /// The uplink level successfully applied to the current connection.
    var uplinkQualityLevel: RealtimeQualityLevel? {
        get async {
            let state = await lifecycleManager.currentState.connectionState
            guard state == .connected || state == .generating else {
                return nil
            }

            return streamController.qualityConfiguration?.uplinkLevel
        }
    }

    /// The downlink level successfully submitted for the current connection.
    var downlinkQualityLevel: RealtimeQualityLevel? {
        get async {
            let state = await lifecycleManager.currentState.connectionState
            guard state == .connected || state == .generating else {
                return nil
            }

            return streamController.qualityConfiguration?.downlinkLevel
        }
    }

    /// The camera's resolved media format, or `nil` for other input sources.
    var currentCameraVideoFormat: RealtimeVideoFormat? {
        get async {
            guard let track = await mediaController.currentTrack, track.device != nil else {
                return nil
            }

            return track.videoFormat
        }
    }

    /// The preset matching current camera dimensions, independent of frame rate or encoding level.
    var currentCameraPreset: RealtimeCameraPreset? {
        get async {
            guard let format = await currentCameraVideoFormat else {
                return nil
            }

            return RealtimeCameraPreset.allCases.first {
                $0.size == format.size
            }
        }
    }

    /// The effective remote frame interpolation state.
    var isFrameInterpolationEnabled: Bool {
        get async {
            await renderController.isFrameInterpolationEnabled
        }
    }

    /// The remote generated audio playback volume in `0...1`.
    var remoteAudioVolume: Float {
        streamController.remoteAudioVolume
    }

    /// Whether the active camera stream requests microphone capture while connected.
    var isMicrophoneEnabled: Bool {
        get async {
            guard !(await mediaController.isExternalVideo) else { return false }
            return await mediaController.hasAudio
        }
    }

    /// Creates a realtime manager with the default components.
    @MainActor
    init(
        options: RealtimeConfiguration,
        apiService: any ApiServicing
    ) {
        self.init(
            options: options,
            components: XmaxRealtimeFactory.make(
                options: options,
                apiService: apiService
            )
        )
    }

    /// Creates a realtime manager with the supplied components.
    init(
        options: RealtimeConfiguration,
        components: XmaxRealtimeComponents
    ) {
        configuration = options
        self.lifecycleManager = components.lifecycleManager
        self.connectionManager = components.connectionManager
        self.generationManager = components.generationManager
        self.errorManager = components.errorManager
        self.mediaController = components.mediaController
        self.renderController = components.renderController
        self.streamController = components.streamController
        self.mediaService = components.mediaService
        self.timing = components.timing
    }

    /// Lists available camera devices.
    func listCameraDevices() async -> [CameraDevice] {
        await mediaController.listCameraDevices()
    }

    /// Lists available microphone devices.
    func listMicrophoneDevices() async -> [MicrophoneDevice] {
        await mediaController.listMicrophoneDevices()
    }

    /// Configures beauty processing for generated video.
    func setRemoteVideoBeauty(
        _ options: RealtimeVideoBeautyOptions?
    ) async throws {
        try await renderController.setRemoteVideoBeauty(options)
    }

    /// Sets the recoverable beauty error listener.
    func setRemoteVideoBeautyErrorListener(
        _ listener: RealtimeVideoBeautyErrorListener?
    ) async {
        await renderController.setRemoteVideoBeautyErrorListener(listener)
    }

    /// Changes the uplink encoding level.
    func setUplinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws {
        try await setQualityLevel(
            level,
            downlink: false
        )
    }

    /// Changes the downlink output level.
    func setDownlinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws {
        try await setQualityLevel(
            level,
            downlink: true
        )
    }

    /// Applies a manual quality change to the active generation task.
    private func setQualityLevel(
        _ level: RealtimeQualityLevel,
        downlink: Bool
    ) async throws {
        try await lifecycleManager.run(kind: .configuration) { [self] token in
            let state = await lifecycleManager.currentState
            try token.ensureCurrent()

            guard state.connectionState == .generating,
                let taskID = state.taskID,
                streamController.qualityConfiguration != nil
            else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Quality levels can only be changed while generating"
                )
            }

            try await connectionManager.applyQualityLevel(
                level,
                downlink: downlink,
                taskID: taskID,
                ensureCurrent: {
                    try token.ensureCurrent()
                }
            )
        }
    }

    /// Sets the microphone input level listener.
    func setMicrophoneLevelListener(
        _ listener: RealtimeMicrophoneLevelListener?
    ) async {
        await mediaController.setMicrophoneLevelListener(listener)
    }

    /// Sets the realtime state listener.
    func setStateListener(
        _ listener: RealtimeStateListener?
    ) async {
        await lifecycleManager.setStateListener(listener)
    }

    /// Sets the startup timing listener.
    func setLaunchTimingListener(
        _ listener: RealtimeLaunchTimingListener?
    ) {
        timing.setListener(listener)
    }

    /// Sets the listener for generated audio and video frames.
    func setRemoteMediaFrameListener(
        _ listener: RealtimeMediaFrameListener?
    ) async throws {
        try await renderController.setRemoteMediaFrameListener(listener)
    }

    /// Sets the upstream video statistics listener.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    ) {
        streamController.setUplinkVideoStatisticsListener(listener)
    }

    /// Sets the downstream video statistics listener.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    ) {
        streamController.setDownlinkVideoStatisticsListener(listener)
    }

    /// Sets the network quality listener.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    ) {
        streamController.setNetworkQualityListener(listener)
    }

    /// Sets the device performance alarm listener.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    ) {
        streamController.setPerformanceAlarmListener(listener)
    }

    /// Sets the playback volume for remote generated audio.
    func setRemoteAudioVolume(
        _ volume: Float
    ) async throws {
        do {
            try Self.validateAudioVolume(volume)
            try streamController.setRemoteAudioVolume(volume)
        } catch {
            throw await reportError(
                XmaxError.from(error)
            )
        }
    }

    /// Enables or disables interpolation of generated remote video.
    func setFrameInterpolationEnabled(
        _ enabled: Bool
    ) async throws {
        try await lifecycleManager.run(kind: .configuration) { [self] token in
            let state = await lifecycleManager.currentState
            let mediaFormat = await mediaController.currentVideoFormat
            try token.ensureCurrent()
            try await connectionManager.setFrameInterpolationEnabled(
                enabled,
                mediaFormat: mediaFormat,
                taskID: state.taskID,
                ensureCurrent: { try token.ensureCurrent() }
            )
        }
    }

    /// Creates a local camera stream and starts preview.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        mirror: Bool = false,
        microphone: RealtimeMicrophone = .disabled
    ) async throws -> RealtimeMediaStream {
        return try await createLocalMediaStream(source: .camera) { [self] token in
            let stream = try await mediaController.createLocalCameraStream(
                videoFormat: videoFormat,
                deviceID: deviceID,
                mirror: mirror,
                microphone: microphone
            )
            try token.ensureCurrent()
            return stream
        }
    }

    /// Updates a ready, disconnected camera format while preserving stream and view bindings.
    func updateCameraFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async throws {
        try await updateCameraFormat { _ in
            videoFormat
        }
    }

    /// Updates camera dimensions while preserving frame rate and encoding settings.
    func updateCameraFormat(
        _ preset: RealtimeCameraPreset
    ) async throws {
        try await updateCameraFormat { current in
            current.resized(
                width: Int(preset.size.width),
                height: Int(preset.size.height)
            )
        }
    }

    /// Applies a format change to a ready, disconnected camera.
    private func updateCameraFormat(
        resolve: @escaping @Sendable (RealtimeVideoFormat) -> RealtimeVideoFormat
    ) async throws {
        try await lifecycleManager.run(kind: .media) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Disconnect realtime before updating the camera format"
            )

            guard await lifecycleManager.currentState.connectionState == .ready,
                let current = await currentCameraVideoFormat
            else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera preview must be ready before updating its format"
                )
            }
            try token.ensureCurrent()

            try await mediaController.updateCameraFormat(resolve(current))
            try token.ensureCurrent()
        }
    }

    /// Stops the local camera stream.
    func stopLocalCameraStream() async throws {
        try await lifecycleManager.run(
            kind: .media
        ) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Disconnect realtime before stopping the local camera stream"
            )
            token.setFailureScope(.all)
            await mediaController.stopLocalCameraStream()
            try await completeLocalMediaStop(token)
        }
    }

    /// Binds an external video source.
    func createExternalVideoStream(
        source: any RealtimeExternalVideoSource,
        videoFormat: RealtimeVideoFormat?
    ) async throws -> RealtimeMediaStream {
        try await createLocalMediaStream(source: .external) { [self] token in
            let stream = try await mediaController.createExternalVideoStream(
                source: source,
                videoFormat: videoFormat
            )
            try token.ensureCurrent()
            return stream
        }
    }

    /// Unbinds external input after connection cleanup, preserving caller capture ownership.
    func stopExternalVideoStream() async throws {
        try await lifecycleManager.run(kind: .media) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Disconnect realtime before stopping the external video stream"
            )
            guard await mediaController.isExternalVideo else { return }
            token.setFailureScope(.all)
            await mediaController.stopExternalVideoStream()
            try await completeLocalMediaStop(token)
        }
    }

    /// Switches the active camera device.
    func switchCamera(
        to deviceID: String
    ) async throws -> RealtimeMediaStream {
        let current = await lifecycleManager.currentState
        guard current.connectionState != .connecting,
            current.connectionState != .disconnecting
        else {
            throw await reportError(
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while realtime " + "is transitioning"
                )
            )
        }
        guard current.connectionState == .generating || !streamController.hasGenerationTask else {
            throw await reportError(
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while " + "realtime generation is starting"
                )
            )
        }

        return try await lifecycleManager.run(
            kind: .cameraSwitch
        ) { [self] token in
            let current = await lifecycleManager.currentState
            guard current.connectionState != .connecting,
                current.connectionState != .disconnecting
            else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while realtime " + "is transitioning"
                )
            }

            let wasGenerating = current.connectionState == .generating
            guard wasGenerating || !streamController.hasGenerationTask else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while " + "realtime generation is starting"
                )
            }

            if wasGenerating {
                token.setFailureScope(.connection)
                try await generationManager.stop(
                    taskID: current.taskID ?? ""
                )
                try await lifecycleManager.commit(
                    RealtimeState(
                        connectionState: .connected,
                        sessionID: current.sessionID
                    ),
                    token: token
                )
            }

            let stream = try await mediaController.switchCamera(to: deviceID)
            try token.ensureCurrent()
            try await connectionManager.reconcileFrameInterpolation(for: stream.videoTrack?.videoFormat)
            if wasGenerating {
                try await Task.sleep(nanoseconds: 500_000_000)
                try await performStartGeneration(
                    context: nil,
                    faceRestoration: await generationManager.cachedFaceRestoration,
                    token: token
                )
            }
            return stream
        }
    }

    /// Changes audio input without replacing the local video track or generation task.
    func switchMicrophone(
        to deviceID: String?
    ) async throws {
        try await lifecycleManager.run(kind: .configuration) { [self] token in
            _ = try await microphoneCaptureState()
            try token.ensureCurrent()
            try await mediaController.switchMicrophone(to: deviceID)
            try token.ensureCurrent()
        }
    }

    /// Changes microphone intent and publication while preserving the current realtime state.
    func setMicrophoneEnabled(
        _ enabled: Bool
    ) async throws {
        try await lifecycleManager.run(kind: .configuration) { [self] token in
            let connected = try await microphoneCaptureState()
            try token.ensureCurrent()
            let previous = await mediaController.hasAudio
            if enabled {
                try await mediaController.setMicrophoneEnabled(true, capture: connected) {
                    try token.ensureCurrent()
                }
                do {
                    try token.ensureCurrent()
                    if connected { try streamController.setLocalAudioPublished(true) }
                    try token.ensureCurrent()
                } catch {
                    if !previous {
                        if connected {
                            do { try streamController.setLocalAudioPublished(false) }
                            catch { XmaxLogger.realtime.error(message: "Failed to roll back microphone publication: \(error)") }
                        }
                        try? await mediaController.setMicrophoneEnabled(false, capture: false, ensureCurrent: {})
                    }
                    throw error
                }
            } else {
                var publicationError: XmaxError?
                if connected {
                    do { try streamController.setLocalAudioPublished(false) }
                    catch { publicationError = XmaxError.from(error) }
                }
                // Stopping physical capture must not depend on a successful channel update.
                try await mediaController.setMicrophoneEnabled(false, capture: false) {
                    try token.ensureCurrent()
                }
                try token.ensureCurrent()
                if let publicationError { throw publicationError }
            }
        }
    }

    /// Validates camera ownership and returns whether microphone capture should currently be running.
    private func microphoneCaptureState() async throws -> Bool {
        let state = await lifecycleManager.currentState
        guard [.ready, .connected, .generating].contains(state.connectionState),
            await mediaController.currentTrack != nil, !(await mediaController.isExternalVideo)
        else {
            throw XmaxError(code: .invalidConfiguration, message: "Microphone changes require a ready camera stream")
        }
        return state.connectionState == .connected || state.connectionState == .generating
    }

    /// Connects the local stream to the realtime session.
    func connect(
        localStream: RealtimeMediaStream
    ) async throws -> RealtimeMediaStream {
        try await lifecycleManager.run(
            kind: .connection
        ) { [self] token in
            try await performConnect(
                localStream: localStream,
                token: token,
                completesOperation: true
            )
        }
    }

    /// Disconnects realtime while retaining the local media preview.
    func disconnect() async {
        await lifecycleManager.disconnect()
    }

    /// Disconnects realtime with the supplied reason.
    func disconnect(
        reason: RealtimeReason
    ) async {
        await lifecycleManager.disconnect(reason: reason)
    }

    /// Closes the realtime session and releases its resources.
    func close() async {
        await lifecycleManager.terminate(
            .all
        )
        await renderController.closeBeauty()
    }

    /// Starts generation or updates the active task.
    func startGeneration(
        context: RealtimeContext?,
        faceRestoration: Bool = false
    ) async throws {
        try await lifecycleManager.run(
            kind: .generation
        ) { [self] token in
            let current = await lifecycleManager.currentState
            try token.ensureCurrent()
            let measuresStartup = current.connectionState == .connected
            if measuresStartup {
                timing.begin()
            }
            do {
                try await performStartGeneration(
                    context: context,
                    faceRestoration: faceRestoration,
                    token: token
                )
            } catch {
                if measuresStartup {
                    timing.finishFailure(error)
                }
                throw error
            }
        }
    }

    /// Connects the local stream if needed and starts generation.
    func startGeneration(
        localStream: RealtimeMediaStream,
        context: RealtimeContext?,
        faceRestoration: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await lifecycleManager.run(
            kind: .generation
        ) { [self] token in
            let initialState = await lifecycleManager.currentState
            let hasConnection = await connectionManager.currentSessionID != ""
            try token.ensureCurrent()
            let measuresStartup =
                initialState.connectionState != .connecting && initialState.connectionState != .disconnecting
                && initialState.connectionState != .generating
            if measuresStartup {
                timing.begin()
            }
            do {
                guard await mediaController.owns(localStream) else {
                    throw XmaxError(
                        code: .invalidConfiguration,
                        message: "The local stream must be created and " + "started by this realtime manager"
                    )
                }
                try token.ensureCurrent()

                _ = try await generationManager.resolveContext(context)
                try token.ensureCurrent()
                let remoteStream: RealtimeMediaStream
                if hasConnection {
                    guard
                        let activeRemoteStream =
                            await connectionManager.currentRemoteStream
                    else {
                        throw XmaxError(
                            code: .rtcError,
                            message: "Realtime connection has no remote stream"
                        )
                    }
                    remoteStream = activeRemoteStream
                } else {
                    remoteStream = try await performConnect(
                        localStream: localStream,
                        token: token
                    )
                }

                try await performStartGeneration(
                    context: context,
                    faceRestoration: faceRestoration,
                    token: token
                )
                return remoteStream
            } catch {
                if measuresStartup {
                    timing.finishFailure(error)
                }
                throw error
            }
        }
    }

    /// Starts generation or updates the active task.
    ///
    /// The failure scope applies to new generation starts.
    private func performStartGeneration(
        context: RealtimeContext?,
        faceRestoration: Bool,
        token: XmaxRealtimeLifecycleManager.Token,
        failureScope: XmaxRealtimeLifecycleManager.TerminationScope = .connection
    ) async throws {
        try token.ensureCurrent()
        let sessionID = await connectionManager.currentSessionID
        let current = await lifecycleManager.currentState
        guard !sessionID.isEmpty,
            current.connectionState == .connected || current.connectionState == .generating,
            let videoFormat = await mediaController.currentVideoFormat
        else {
            throw XmaxError(
                code: .rtcError,
                message: "Realtime connection is not open"
            )
        }

        let generationSize = try mediaService.resolveGenerationSize(videoFormat.size)
        let generationFormat = videoFormat.resized(
            width: Int(generationSize.width),
            height: Int(generationSize.height)
        )
        let paddingContain = videoFormat.width * generationFormat.height != videoFormat.height * generationFormat.width
        try token.ensureCurrent()

        if current.connectionState == .generating,
            let taskID = current.taskID
        {
            try await generationManager.update(
                taskID: taskID,
                videoFormat: videoFormat,
                targetSize: nil,
                context: context,
                faceRestoration: faceRestoration,
                generationVideoFormat: generationFormat,
                paddingContain: paddingContain,
                ensureCurrent: { try token.ensureCurrent() }
            )
            try token.ensureCurrent()
            return
        }

        _ = try await generationManager.resolveContext(context)
        try token.ensureCurrent()
        token.setFailureScope(failureScope)
        let taskID = try await generationManager.start(
            videoFormat: videoFormat,
            targetSize: await connectionManager.currentTargetSize,
            context: context,
            faceRestoration: faceRestoration,
            generationVideoFormat: generationFormat,
            paddingContain: paddingContain,
            ensureCurrent: {
                try token.ensureCurrent()
            }
        )
        try token.ensureCurrent()
        guard await connectionManager.currentSessionID == sessionID else {
            throw XmaxError(
                code: .cancelled,
                message: "Realtime connection was cancelled"
            )
        }
        await connectionManager.completeInitialQuality()
        if configuration.isAdaptiveQualityEnabled {
            streamController.setAdaptiveQualityListener { [weak self] quality, time in
                Task {
                    await self?.adaptQuality(
                        quality,
                        sampledAt: time,
                        taskID: taskID
                    )
                }
            }
        } else {
            streamController.setAdaptiveQualityListener(nil)
        }
        try await lifecycleManager.complete(
            RealtimeState(
                connectionState: .generating,
                sessionID: sessionID,
                taskID: taskID
            ),
            token: token
        )
        try token.ensureCurrent()
        timing.finish(taskID: taskID)
    }
}

private extension XmaxRealtimeManager {

    /// Applies automatic quality changes for the active task when configuration is idle.
    ///
    /// - Parameter sampledAt: The sample's monotonic system time in seconds.
    func adaptQuality(
        _ sample: RealtimeNetworkQuality,
        sampledAt: TimeInterval,
        taskID: String
    ) async {
        guard !qualityPending else { return }
        qualityPending = true
        defer { qualityPending = false }
        do {
            let accepted = try await lifecycleManager.runAdaptiveConfiguration { [self] token in
                let state = await lifecycleManager.currentState
                try token.ensureCurrent()
                guard state.taskID == taskID, state.connectionState == .generating else { return }
                let change = streamController.proposeQuality(
                    sample,
                    sampledAt: sampledAt
                )
                if let level = change.uplink {
                    try? await connectionManager.applyQualityLevel(
                        level,
                        downlink: false,
                        taskID: taskID,
                        ensureCurrent: { try token.ensureCurrent() }
                    )
                }
                try token.ensureCurrent()
                if let level = change.downlink {
                    try? await connectionManager.applyQualityLevel(
                        level,
                        downlink: true,
                        taskID: taskID,
                        ensureCurrent: { try token.ensureCurrent() }
                    )
                }
            }
            if !accepted { streamController.resetQualitySamples() }
        } catch {
            // Cancellation and disconnect samples do not belong to a new connection or override its configuration.
            if !Task.isCancelled, await lifecycleManager.currentState.taskID == taskID {
                streamController.resetQualitySamples()
            }
        }
    }

    /// Connects and publishes the local stream.
    ///
    /// Pass `completesOperation: false` when the same operation continues into generation.
    func performConnect(
        localStream: RealtimeMediaStream,
        token: XmaxRealtimeLifecycleManager.Token,
        completesOperation: Bool = false
    ) async throws -> RealtimeMediaStream {
        let current = await lifecycleManager.currentState
        guard await connectionManager.currentSessionID == "",
            current.connectionState != .connecting,
            current.connectionState != .disconnecting
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Realtime connection is already open"
            )
        }
        guard await mediaController.owns(localStream) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "The local stream must be created and started " + "by this realtime manager"
            )
        }

        try token.ensureCurrent()
        guard let videoFormat = localStream.videoTrack?.videoFormat else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Local video format is unavailable"
            )
        }

        token.setFailureScope(.connection)
        try await generationManager.reset()
        try token.ensureCurrent()
        try await lifecycleManager.commit(
            RealtimeState(connectionState: .connecting),
            token: token
        )
        let preparedQuality = try await connectionManager.prepareQuality(
            baseline: videoFormat,
            options: configuration,
            ensureCurrent: { try token.ensureCurrent() }
        )
        let targetSize = preparedQuality.targetSize
        try token.ensureCurrent()
        if !(await mediaController.isExternalVideo) {
            // Let camera startup exposure settle before connecting and publishing local media.
            try await Task.sleep(for: .milliseconds(500))
            try token.ensureCurrent()
        }
        try await mediaController.startMicrophoneCapture()
        try token.ensureCurrent()
        let remoteStream = try await connectionManager.connect(
            model: configuration.model,
            videoFormat: videoFormat,
            targetSize: targetSize,
            includeLocalAudio: await mediaController.hasAudio,
            isCurrent: { token.isCurrent },
            onHeartbeatFailure: { [weak self] sessionID, error in
                await self?.handleHeartbeatFailure(
                    sessionID: sessionID,
                    error: error
                )
            }
        )
        try token.ensureCurrent()
        let sessionID = await connectionManager.currentSessionID
        guard !sessionID.isEmpty else {
            throw XmaxError(
                code: .cancelled,
                message: "Realtime connection was cancelled"
            )
        }

        let connectedState = RealtimeState(
            connectionState: .connected,
            sessionID: sessionID
        )
        if completesOperation {
            try await lifecycleManager.complete(
                connectedState,
                token: token
            )
        } else {
            try await lifecycleManager.commit(
                connectedState,
                token: token
            )
        }
        return remoteStream
    }

    /// Prepares a local media stream.
    ///
    /// Camera readiness requires active capture and a bound preview.
    func createLocalMediaStream(
        source: RealtimeMediaSource,
        prepare:
            @escaping @Sendable (XmaxRealtimeLifecycleManager.Token) async throws
            -> RealtimeMediaStream
    ) async throws -> RealtimeMediaStream {
        return try await lifecycleManager.run(
            kind: .media
        ) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Local \(source.rawValue) stream is unavailable during " + "a realtime connection"
            )
            guard await mediaController.currentTrack == nil else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Stop the current local media stream before creating another one"
                )
            }
            try token.ensureCurrent()
            errorManager.invalidatePendingFailures()
            try await lifecycleManager.commit(
                RealtimeState(connectionState: .preparing),
                token: token
            )
            try token.ensureCurrent()

            let stream = try await prepare(token)
            try token.ensureCurrent()
            token.setFailureScope(.all)
            _ = try await connectionManager.reconcileFrameInterpolation(for: stream.videoTrack?.videoFormat)
            try token.ensureCurrent()
            try streamController.setRemoteAudioVolume(0)
            if source == .camera {
                await mediaController.setCameraPreviewReadyHandler { [lifecycleManager] isCurrent in
                    Task {
                        await lifecycleManager.localPreviewDidBecomeReady(isCurrent: isCurrent)
                    }
                }
            } else {
                try await lifecycleManager.complete(
                    RealtimeState(connectionState: .ready),
                    token: token
                )
            }
            return stream
        }
    }

    /// Restores readiness or idle state after a local media stop.
    func completeLocalMediaStop(
        _ token: XmaxRealtimeLifecycleManager.Token
    ) async throws {
        try token.ensureCurrent()
        errorManager.invalidatePendingFailures()
        let hasLocalMedia = await mediaController.currentTrack != nil
        try await lifecycleManager.complete(
            RealtimeState(connectionState: hasLocalMedia ? .ready : .idle),
            token: token
        )
    }

    /// Requires a fully disconnected session before local media can change.
    func ensureLocalMediaCanChange(
        message: String
    ) async throws {
        let current = await lifecycleManager.currentState
        guard await connectionManager.currentSessionID == "",
            current.connectionState != .connecting,
            current.connectionState != .disconnecting
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: message
            )
        }
    }

    /// Ends the current session after heartbeat failure and ignores late notifications from ended sessions.
    func handleHeartbeatFailure(
        sessionID: String,
        error: XmaxError
    ) async {
        guard await connectionManager.currentSessionID == sessionID else {
            return
        }
        await lifecycleManager.terminate(
            with: error,
            target: .connection
        )
    }

    /// Reports an error and returns it as an SDK error.
    @discardableResult
    func reportError(
        _ error: any Error
    ) async -> XmaxError {
        let xmaxError = XmaxError.from(error)
        await errorManager.report(xmaxError)
        return xmaxError
    }

    /// Requires a finite playback volume in `0...1`.
    static func validateAudioVolume(
        _ volume: Float
    ) throws {
        guard volume.isFinite, (0...1).contains(volume) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Audio volume must be between 0 and 1"
            )
        }
    }

}

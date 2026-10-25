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

/// Public realtime generation entry point coordinating local media, connection, generation, and state notifications.
actor XmaxRealtimeManager: XmaxRealtimeManaging {

    /// The model, interpolation, and adaptive quality configuration supplied at creation.
    nonisolated let options: RealtimeConfiguration

    // MARK: - Dependencies

    /// The operation admission and resource cleanup owner.
    private let lifecycleManager: XmaxRealtimeLifecycleManager

    /// The server session, transport quality, and remote output owner.
    private let connectionManager: XmaxRealtimeConnectionManager

    /// The generation signaling and result readiness owner.
    private let generationManager: XmaxRealtimeGenerationManager

    /// The shared failure reporting and routing component.
    private let errorManager: XmaxRealtimeErrorManager

    /// The local media and interaction controller.
    private let mediaController: any MediaControlling

    /// The remote rendering and processed frame controller.
    private let renderController: any RenderControlling

    /// The RTC publishing, signaling, and quality controller.
    private let streamController: any StreamControlling

    /// The service resolving media and generation dimensions.
    private let mediaService: any MediaServicing

    /// The shared startup duration recorder.
    private let timing: RealtimeTiming

    /// Whether an adaptive quality request is already pending.
    private var qualityPending = false

    /// Creates a realtime facade using the default SDK components.
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

    /// Creates a realtime facade with the supplied component ownership graph.
    init(
        options: RealtimeConfiguration,
        components: XmaxRealtimeComponents
    ) {
        self.options = options
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

    /// Assembles supplied dependencies using the same lifecycle wiring as production.
    init(
        options: RealtimeConfiguration,
        streamController: any StreamControlling,
        mediaController: any MediaControlling,
        renderController: any RenderControlling,
        mediaService: any MediaServicing = MediaService(),
        connectionManager: XmaxRealtimeConnectionManager,
        errorManager: XmaxRealtimeErrorManager,
        generationManager: XmaxRealtimeGenerationManager,
        timing: RealtimeTiming = RealtimeTiming()
    ) {
        self.init(
            options: options,
            components: XmaxRealtimeFactory.assemble(
                connectionManager: connectionManager,
                generationManager: generationManager,
                errorManager: errorManager,
                mediaController: mediaController,
                renderController: renderController,
                streamController: streamController,
                mediaService: mediaService,
                timing: timing
            )
        )
    }

    /// Lists currently available camera devices.
    ///
    /// - Returns: The currently selectable system video devices.
    func listCameraDevices() async -> [CameraDevice] {
        await mediaController.listCameraDevices()
    }

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

    /// Changes the uplink encoding level while allowing subsequent automatic adaptation.
    ///
    /// - Parameter level: The requested uplink quality level.
    ///
    /// - Throws: An error if generation is inactive, an operation conflicts or is cancelled, or
    ///   encoder configuration fails.
    func setUplinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws {
        try await setQualityLevel(
            level,
            downlink: false
        )
    }

    /// Changes the downlink output level while allowing subsequent automatic adaptation.
    ///
    /// - Parameter level: The requested downlink quality level.
    ///
    /// - Throws: An error if generation is inactive, an operation conflicts or is cancelled, or
    ///   signaling or rendering configuration fails.
    func setDownlinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws {
        try await setQualityLevel(
            level,
            downlink: true
        )
    }

    /// Changes the requested uplink or downlink quality level.
    ///
    /// - Parameters:
    ///   - level: The requested transport quality level.
    ///   - downlink: Whether to change downlink output rather than uplink encoding.
    ///
    /// - Throws: An error if the state is invalid, an operation conflicts or is cancelled, or the
    ///   level cannot be applied.
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

    /// Sets the realtime state listener.
    ///
    /// - Parameter listener: The realtime state callback; `nil` clears the listener.
    func setStateListener(
        _ listener: RealtimeStateListener?
    ) async {
        await lifecycleManager.setStateListener(listener)
    }

    /// Sets the startup timing listener using the same records as performance logs.
    ///
    /// - Parameter listener: The main-thread snapshot callback; `nil` clears the listener.
    func setLaunchTimingListener(
        _ listener: RealtimeLaunchTimingListener?
    ) {
        timing.setListener(listener)
    }

    /// Sets serialized remote PCM and processed video output without changing playback.
    ///
    /// - Parameter listener: The output handler, or `nil` to stop output.
    ///
    /// - Throws: An error if the current remote audio listener cannot be configured.
    func setRemoteMediaFrameListener(
        _ listener: RealtimeMediaFrameListener?
    ) async throws {
        try await renderController.setRemoteMediaFrameListener(listener)
    }

    /// Sets the final remote video frame listener.
    ///
    /// Receives frames after optional interpolation, immediately before display. The SDK invokes the callback
    /// on an internal serial queue without blocking the main thread. Forward frames promptly and avoid
    /// expensive encoding in the callback. Pass `nil` to clear the listener.
    ///
    /// - Parameter listener: The final remote video frame callback.
    func setRemoteVideoFrameListener(
        _ listener: RealtimeVideoFrameListener?
    ) async {
        await renderController.setRemoteVideoFrameListener(listener)
    }

    /// Sets the upstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil before publication or after disconnect. Pass nil to
    ///   clear it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    ) {
        streamController.setUplinkVideoStatisticsListener(listener)
    }

    /// Sets the downstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil when the result stream is cleared. Pass nil to
    ///   clear it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    ) {
        streamController.setDownlinkVideoStatisticsListener(listener)
    }

    /// Sets the network quality listener.
    ///
    /// - Parameter listener: The upstream and downstream network quality callback; `nil` clears the listener.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    ) {
        streamController.setNetworkQualityListener(listener)
    }

    /// Sets the device performance alarm listener.
    ///
    /// - Parameter listener: The device performance alarm callback; `nil` clears the listener.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    ) {
        streamController.setPerformanceAlarmListener(listener)
    }

    /// Sets the playback volume for remote generated audio.
    ///
    /// Stores the setting before connection or subscription and applies it before remote audio playback starts.
    /// Call after creating the local stream to override the initial volume.
    ///
    /// - Parameter volume: The remote playback volume in `0...1`.
    ///
    /// - Throws: An error if the volume is out of range or RTC volume configuration fails.
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
    ///
    /// Overrides the initial setting. During generation, enabling requests proportionally smaller return dimensions;
    /// disabling restores dimensions for the current network tier, without reconnecting or restarting generation.
    /// Original frames remain visible during the dimension change.
    ///
    /// - Parameter enabled: Whether to enable remote video interpolation.
    ///
    /// - Throws: An error on conflicting operations, unsupported devices or dimensions, or signal delivery failure.
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
    ///
    /// Bind the returned track to a preview view; media becomes `ready` after native capture starts and the view is
    /// bound.
    ///
    /// - Parameters:
    ///   - videoFormat: The camera capture video format.
    ///   - deviceID: The initial device identifier; an empty value uses the system default camera.
    ///   - mirror: Whether to mirror local preview and the encoded camera stream; disabled by default.
    ///   - useMicrophone: Whether to use the microphone; requests permission at creation, starts capture on connection,
    ///     and stops on disconnect.
    ///
    /// - Returns: The media stream containing the local camera video track.
    ///
    /// - Throws: An error on invalid configuration, denied permissions, conflicting operations, or capture startup
    ///   failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        mirror: Bool = false,
        useMicrophone: Bool = false
    ) async throws -> RealtimeMediaStream {
        return try await createLocalMediaStream(source: .camera) { [self] token in
            let stream = try await mediaController.createLocalCameraStream(
                videoFormat: videoFormat,
                deviceID: deviceID,
                mirror: mirror,
                useMicrophone: useMicrophone
            )
            try token.ensureCurrent()
            return stream
        }
    }

    /// Updates a ready, disconnected camera format while preserving stream and view bindings.
    ///
    /// - Parameter videoFormat: The supported camera dimensions, frame rate, and encoding settings.
    ///
    /// - Throws: An error if the state or format is invalid, an operation conflicts, or device
    ///   configuration fails.
    func updateCameraFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async throws {
        try await updateCameraFormat { _ in
            videoFormat
        }
    }

    /// Updates camera dimensions while preserving frame rate and encoding settings.
    ///
    /// - Parameter preset: The requested resolution preset.
    ///
    /// - Throws: An error if the state or preset is invalid, an operation conflicts, or capture
    ///   configuration fails.
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

    /// Updates the camera format using its current settings.
    ///
    /// - Parameter resolve: A closure deriving the requested format from the current camera format.
    ///
    /// - Throws: An error if the camera is not ready, realtime is connected, or configuration
    ///   fails.
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

    /// Stops the local camera stream and updates media readiness.
    ///
    /// - Throws: An error if realtime is still connected, a conflicting operation exists, or this operation is
    ///   cancelled.
    func stopLocalCameraStream() async throws {
        try await lifecycleManager.run(
            kind: .media
        ) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Disconnect realtime before stopping the local " + "camera stream"
            )
            token.setFailureScope(.all)
            await mediaController.stopLocalCameraStream()
            try token.ensureCurrent()
            errorManager.invalidatePendingFailures()
            let hasLocalMedia = await mediaController.currentTrack != nil
            try await lifecycleManager.complete(
                RealtimeState(connectionState: hasLocalMedia ? .ready : .idle),
                token: token
            )
        }
    }

    /// Binds external video input with model-validated dimensions and optional caller preview.
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
            try token.ensureCurrent()
            errorManager.invalidatePendingFailures()
            let hasLocalMedia = await mediaController.currentTrack != nil
            try await lifecycleManager.complete(
                RealtimeState(connectionState: hasLocalMedia ? .ready : .idle),
                token: token
            )
        }
    }

    /// Switches the active camera device.
    ///
    /// During generation, the SDK stops generation, switches cameras, and resumes with cached conditions.
    /// The RTC connection is retained. Camera switching is unavailable while connection or generation starts.
    ///
    /// - Returns: The local stream retaining the original video track with its camera position updated.
    ///
    /// - Throws: An error if no camera stream exists, realtime startup is in progress, or camera switching or
    ///   generation recovery
    ///   fails.
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

    /// Establishes a realtime connection with the local stream created by this manager.
    ///
    /// - Parameter localStream: The local media stream created and owned by this manager.
    ///
    /// - Returns: The connected remote media stream, which can be bound to a result preview view.
    ///
    /// - Throws: An error on invalid local stream, existing connection, conflicting operation, cancellation, or
    ///   connection failure.
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

    /// Disconnects realtime for a business reason while retaining usable local media.
    ///
    /// - Parameter reason: The disconnect reason, such as a display orientation change.
    func disconnect(
        reason: RealtimeReason
    ) async {
        await lifecycleManager.disconnect(reason: reason)
    }

    /// Closes the realtime lifecycle and releases the connection, local media, and RTC engine.
    ///
    /// Concurrent close calls await the same cleanup task; local streams can be created again after close completes.
    func close() async {
        await lifecycleManager.terminate(
            .all
        )
    }

    /// Starts generation, or updates current conditions if generation is already active.
    ///
    /// - Parameters:
    ///   - context: The generation conditions; required initially. Later calls may pass `nil` to reuse cached
    ///     conditions.
    ///   - faceRestoration: Whether to restore the original face; each call sends this setting.
    ///
    /// - Throws: An error if conditions are invalid or generation startup or update fails.
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

    /// Connects using the current local stream when needed and starts generation.
    ///
    /// Reuses an existing connection. The returned remote stream can display results in the unified video view.
    ///
    /// - Parameters:
    ///   - localStream: The local media stream created and owned by this manager.
    ///   - context: The generation conditions; required for initial generation.
    ///   - faceRestoration: Whether to restore the original face; each call sends this setting.
    ///
    /// - Returns: The remote media stream for the current RTC connection.
    ///
    /// - Throws: An error on invalid local stream, connection failure, or generation startup failure.
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

                try await generationManager.validateContext(context)
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

    /// Starts the result stream and commits generation state, or updates the active task's conditions.
    ///
    /// - Parameters:
    ///   - context: The generation conditions; nil reuses the last successful request's conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - token: The operation token used to validate the current lifecycle.
    ///
    /// - Throws: An error on unavailable connection, invalid conditions, cancellation, or generation startup or update
    ///   failure.
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

        try await generationManager.validateContext(context)
        try token.ensureCurrent()
        token.setFailureScope(failureScope)
        do {
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
            if options.isAdaptiveQualityEnabled {
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
        } catch {
            throw error
        }
    }
}

private extension XmaxRealtimeManager {

    /// Attempts automatic quality adjustment for the current task's network sample; skips it while busy.
    ///
    /// - Parameters:
    ///   - sample: The upstream and downstream network quality sample.
    ///   - sampledAt: The sample's monotonic system time in seconds.
    ///   - taskID: The generation task identifier associated with the sample.
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

    /// Publishes local media, establishes a realtime session, and commits the connected state on success.
    ///
    /// - Parameters:
    ///   - localStream: The local media stream created and owned by this manager.
    ///   - token: The lifecycle token for this connection operation.
    ///   - completesOperation: Whether this connection ends the operation; `false` keeps the
    ///     connected state as an intermediate step before generation.
    ///
    /// - Returns: The remote media stream for this session.
    ///
    /// - Throws: An error on an existing connection, invalid local stream, cancellation, or session or RTC connection
    ///   failure.
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
            options: options,
            ensureCurrent: { try token.ensureCurrent() }
        )
        let targetSize = preparedQuality.targetSize
        try token.ensureCurrent()
        try await mediaController.startMicrophoneCapture()
        try token.ensureCurrent()
        let remoteStream = try await connectionManager.connect(
            model: options.model,
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

    /// Creates local media and configures orientation, initial volume, and media readiness notifications.
    ///
    /// - Parameters:
    ///   - source: The media source being created.
    ///   - prepare: The asynchronous stream creation operation receiving the current lifecycle token.
    ///
    /// - Returns: The prepared local stream; camera readiness requires active capture and a bound preview.
    ///
    /// - Throws: An error if a local stream or realtime connection exists, or preparation fails or is cancelled.
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

    /// Checks that no realtime connection prevents local media changes.
    ///
    /// - Parameter message: The error message when media changes are disallowed.
    ///
    /// - Throws: An error if a session exists or connection setup or teardown is in progress.
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
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier whose heartbeat failed.
    ///   - error: The heartbeat request error.
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

    /// Logs and converts an error into the unified SDK error type.
    ///
    /// - Parameter error: The original error to log and convert.
    ///
    /// - Returns: The XmaxError for the caller to throw or handle.
    @discardableResult
    func reportError(
        _ error: any Error
    ) async -> XmaxError {
        let xmaxError = XmaxError.from(error)
        await errorManager.report(xmaxError)
        return xmaxError
    }

    /// Checks that volume is finite and within 0...1.
    ///
    /// - Parameter volume: The playback volume to apply.
    ///
    /// - Throws: An error if the volume is nonfinite or out of range.
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

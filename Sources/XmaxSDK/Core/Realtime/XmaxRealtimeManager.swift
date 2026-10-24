//
//  XmaxRealtimeManager.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Public realtime generation entry point coordinating local media, connection, generation, and state notifications.
actor XmaxRealtimeManager: XmaxRealtimeManaging {

    /// Public configuration
    nonisolated let options: RealtimeConfiguration

    /// Business layer components
    private let renderController: any RenderControlling
    private let streamController: any StreamControlling
    private let mediaController: any MediaControlling

    /// Service components
    private let mediaService: any MediaServicing

    /// Realtime management components
    private let connectionManager: XmaxRealtimeConnectionManager
    private let generationManager: XmaxRealtimeGenerationManager

    /// Errors and timing records
    private let errorHandler: RealtimeErrorHandler
    private let timing: RealtimeTiming

    /// Concurrency control
    private let coordinator: RealtimeCoordinator

    /// Automatic quality adjustment
    private var qualityPending = false

    /// Creates realtime generation components and connects media, transport, rendering, and lifecycle management.
    ///
    /// - Parameters:
    ///   - options: The model and initial interpolation setting.
    ///   - apiService: The API service for creating and closing realtime sessions.
    @MainActor
    init(
        options: RealtimeConfiguration,
        apiService: any ApiServicing
    ) {
        self.options = options

        let errorHandler = RealtimeErrorHandler()
        let rtcManager = RtcManager()
        let mediaService = MediaService(model: options.model)
        let timing = RealtimeTiming()

        let renderController = RenderController(
            rtcManager: rtcManager,
            frameInterpolationEnabled:
                options.isFrameInterpolationEnabled,
            frameInterpolationSupportChecker: {
                mediaService.supportsFrameInterpolation(for: $0)
            },
            errorListener: { errorHandler.forward($0, target: .connection) }
        )

        let streamController = StreamController(
            rtcManager: rtcManager,
            errorListener: { errorHandler.forward($0, target: .connection) },
            remoteStreamListener: { stream in
                try renderController.setRemoteStream(stream)
            },
            timing: timing
        )

        let mediaController = MediaController(
            rtcManager: rtcManager,
            mediaService: mediaService,
            videoFrameListener: { frame in
                try streamController.pushLocalVideoFrame(frame)
            },
            requestingFrames: { streamController.hasGenerationTask },
            errorListener: { errorHandler.forward($0, target: .all) },
            interactionListener: { taskID, points in
                try await streamController.sendTracks(
                    taskID: taskID,
                    points: points
                )
            }
        )

        let connectionManager = XmaxRealtimeConnectionManager(
            sessionService: RealtimeSessionService(apiService: apiService),
            interactionController: mediaController,
            renderController: renderController,
            streamController: streamController,
            timing: timing
        )

        let generationManager = XmaxRealtimeGenerationManager(
            interactionController: mediaController,
            streamController: streamController,
            renderController: renderController
        )
        let coordinator = RealtimeCoordinator(
            errorHandler: errorHandler,
            cleanup: { scope, taskID in
                await XmaxRealtimeManager.cleanup(
                    scope: scope,
                    taskID: taskID,
                    mediaController: mediaController,
                    connectionManager: connectionManager,
                    generationManager: generationManager
                )
            },
            stopLocalCapture: { await mediaController.stopLocalCapture() }
        )

        self.streamController = streamController
        self.mediaController = mediaController
        self.renderController = renderController
        self.mediaService = mediaService
        self.connectionManager = connectionManager
        self.errorHandler = errorHandler
        self.generationManager = generationManager
        self.timing = timing
        self.coordinator = coordinator

        errorHandler.setFailureHandler { [weak coordinator] error, target, isCurrent in
            await coordinator?.terminate(
                with: error,
                target: target,
                isCurrent: isCurrent
            )
        }
    }

    /// Creates a realtime generation manager with the specified business components.
    ///
    /// - Parameters:
    ///   - options: The model and initial interpolation setting.
    ///   - streamController: The component managing RTC transport, signals, and network quality.
    ///   - mediaController: The component managing local media and trajectory interaction.
    ///   - renderController: The component managing video track display and interpolation.
    ///   - mediaService: The service providing model dimension and interpolation capability rules.
    ///   - connectionManager: The component managing server sessions and remote media resources.
    ///   - errorHandler: The component recording errors and forwarding lifecycle failures.
    ///   - generationManager: The component managing generation tasks and condition updates.
    ///   - timing: The component recording startup stage timings.
    init(
        options: RealtimeConfiguration,
        streamController: any StreamControlling,
        mediaController: any MediaControlling,
        renderController: any RenderControlling,
        mediaService: any MediaServicing = MediaService(),
        connectionManager: XmaxRealtimeConnectionManager,
        errorHandler: RealtimeErrorHandler,
        generationManager: XmaxRealtimeGenerationManager,
        timing: RealtimeTiming = RealtimeTiming()
    ) {
        self.options = options
        self.streamController = streamController
        self.mediaController = mediaController
        self.renderController = renderController
        self.mediaService = mediaService
        self.connectionManager = connectionManager
        self.errorHandler = errorHandler
        self.generationManager = generationManager
        self.timing = timing
        let coordinator = RealtimeCoordinator(
            errorHandler: errorHandler,
            cleanup: { scope, taskID in
                await XmaxRealtimeManager.cleanup(
                    scope: scope,
                    taskID: taskID,
                    mediaController: mediaController,
                    connectionManager: connectionManager,
                    generationManager: generationManager
                )
            },
            stopLocalCapture: { await mediaController.stopLocalCapture() }
        )
        self.coordinator = coordinator
        errorHandler.setFailureHandler { [weak coordinator] error, target, isCurrent in
            await coordinator?.terminate(with: error, target: target, isCurrent: isCurrent)
        }
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
            await coordinator.currentState
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

    /// Sets the realtime state listener.
    ///
    /// - Parameter listener: The realtime state callback; `nil` clears the listener.
    func setStateListener(_ listener: RealtimeStateListener?) async {
        await coordinator.setStateListener(listener)
    }

    /// Sets the startup timing listener using the same records as performance logs.
    ///
    /// - Parameter listener: The main-thread snapshot callback; `nil` clears the listener.
    func setLaunchTimingListener(_ listener: RealtimeLaunchTimingListener?) {
        timing.setListener(listener)
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
    /// - Parameter listener: The main-thread callback; receives nil before publication or after disconnect. Pass nil to clear it.
    func setUplinkVideoStatisticsListener(_ listener: UplinkVideoStatisticsListener?) {
        streamController.setUplinkVideoStatisticsListener(listener)
    }

    /// Sets the downstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil when the result stream is cleared. Pass nil to clear it.
    func setDownlinkVideoStatisticsListener(_ listener: DownlinkVideoStatisticsListener?) {
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
    /// - Throws: An error if the volume is out of range or RTC volume configuration fails.
    func setRemoteAudioVolume(_ volume: Float) async throws {
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
    /// - Throws: An error on conflicting operations, unsupported devices or dimensions, or signal delivery failure.
    func setFrameInterpolationEnabled(_ enabled: Bool) async throws {
        try await coordinator.run(
            kind: .configuration
        ) { [self] token in
            do {
                let current = await coordinator.currentState
                let mediaFormat = await mediaController.currentVideoFormat
                let targetSize = try mediaFormat.map {
                    try resolveTargetVideoFormat(
                        baseline: $0,
                        level: streamController.qualityConfiguration?.downlinkLevel ?? 2,
                        interpolation: enabled
                    ).size
                }
                if enabled, let targetSize,
                   !mediaService.supportsFrameInterpolation(for: targetSize) {
                    throw XmaxError(
                        code: .frameInterpolationUnsupported,
                        message: "Frame interpolation is unavailable for " +
                            "\(Int(targetSize.width)) × \(Int(targetSize.height)) video"
                    )
                }
                try token.ensureCurrent()
                if let taskID = current.taskID, let targetSize,
                   await connectionManager.currentTargetSize != targetSize {
                    try await streamController.changeTargetSize(
                        taskID: taskID,
                        targetSize: targetSize,
                        ensureActive: { try token.ensureCurrent() }
                    )
                }

                // Commits local configuration after sending the signal; concurrent disconnect waits for this operation before cleanup.
                if let mediaFormat, let targetSize {
                    await connectionManager.updateTargetSize(targetSize, videoFormat: mediaFormat)
                }
                var returnFormat = mediaFormat
                if let mediaFormat, let targetSize {
                    returnFormat = mediaFormat.resized(
                        width: Int(targetSize.width),
                        height: Int(targetSize.height)
                    )
                }
                try await renderController.setFrameInterpolationEnabled(
                    enabled,
                    videoFormat: returnFormat
                )
            } catch {
                throw XmaxError.from(error)
            }
        }
    }

    /// Creates a local camera stream and starts preview.
    ///
    /// Bind the returned track to a preview view; media becomes `ready` after native capture starts and the view is bound.
    ///
    /// - Parameters:
    ///   - videoFormat: The camera capture video format.
    ///   - deviceID: The initial device identifier; an empty value uses the system default camera.
    ///   - useMicrophone: Whether to use the microphone; requests permission at creation, starts capture on connection, and stops on disconnect.
    /// - Returns: The media stream containing the local camera video track.
    /// - Throws: An error on invalid configuration, denied permissions, conflicting operations, or capture startup failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        useMicrophone: Bool = false
    ) async throws -> RealtimeMediaStream {
        let trace = LocalMediaPreparationTiming.Trace()
        return try await LocalMediaPreparationTiming.$current.withValue(trace) {
            try await LocalMediaPreparationTiming.measureAsync(.total) {
                try await createLocalMediaStream(source: .camera) { [self] token in
                    timing.beginCameraPreparation()
                    let stream = try await mediaController.createLocalCameraStream(
                        videoFormat: videoFormat,
                        deviceID: deviceID,
                        useMicrophone: useMicrophone,
                        retainRTCOnFailure: false
                    )
                    try token.ensureCurrent()
                    timing.finishCameraPreparation()
                    return stream
                }
            }
        }
    }

    /// Runs camera preparation and cloud joining as children of one cancellable lifecycle operation.
    func startCameraGeneration(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        useMicrophone: Bool,
        context: RealtimeContext,
        faceRestoration: Bool,
        localStreamListener: @escaping @MainActor @Sendable (RealtimeMediaStream) -> Void
    ) async throws -> RealtimeMediaStream {
        let trace = LocalMediaPreparationTiming.Trace()
        return try await LocalMediaPreparationTiming.$current.withValue(trace) {
            try await coordinator.run(kind: .generation) { [self] token in
                try await ensureLocalMediaCanChange(message: "Camera startup requires an idle manager")
                guard await mediaController.currentTrack == nil else {
                    throw XmaxError(code: .invalidConfiguration, message: "Stop the current local stream before camera startup")
                }
                try videoFormat.validate()
                try await generationManager.validateContext(context)
                let size = try mediaService.resolveMediaSize(videoFormat.size, source: .camera)
                let format = videoFormat.resized(width: Int(size.width), height: Int(size.height))
                try format.validate()
                try token.ensureCurrent()
                token.setFailureScope(.all)
                errorHandler.invalidatePendingFailures()
                timing.begin()
                timing.beginCameraPreparation()
                do {
                    try await coordinator.commit(RealtimeState(connectionState: .preparing), token: token)
                    try await LocalMediaPreparationTiming.measureAsync(.engineAcquire) {
                        try await mediaController.initializeRTC()
                    }
                    try token.ensureCurrent()
                    let quality = streamController.prepareQuality(baseline: format, model: options.model.rawValue)
                    let targetSize = try await reconcileFrameInterpolation(videoFormat: format)
                    try streamController.setRemoteAudioVolume(0)
                    try await coordinator.commit(RealtimeState(connectionState: .connecting), token: token)

                    let gate = CameraStartupGate()
                    enum Branch: Sendable { case camera, connection(RealtimeMediaStream) }
                    let remote = try await withThrowingTaskGroup(of: Branch.self) { group in
                        group.addTask { [self] in
                            let local = try await LocalMediaPreparationTiming.measureAsync(.total) {
                                try await mediaController.createLocalCameraStream(
                                    videoFormat: format, deviceID: deviceID, useMicrophone: useMicrophone,
                                    retainRTCOnFailure: true
                                )
                            }
                            try Task.checkCancellation()
                            try token.ensureCurrent()
                            timing.finishCameraPreparation()
                            await localStreamListener(local)
                            try await mediaController.startMicrophoneCapture()
                            try Task.checkCancellation()
                            try token.ensureCurrent()
                            await gate.ready()
                            return .camera
                        }
                        group.addTask { [self] in
                            let remote = try await connectionManager.connect(
                                model: options.model, videoFormat: format, targetSize: targetSize,
                                includeLocalAudio: useMicrophone,
                                beforePublication: {
                                    try await gate.wait()
                                    try token.ensureCurrent()
                                    try self.streamController.setVideoEncoderConfig(quality.uplink)
                                },
                                isCurrent: { token.isCurrent && !Task.isCancelled },
                                onHeartbeatFailure: { [weak self] sessionID, error in
                                    await self?.handleHeartbeatFailure(sessionID: sessionID, error: error)
                                }
                            )
                            return .connection(remote)
                        }
                        defer { group.cancelAll() }
                        var result: RealtimeMediaStream?
                        for try await branch in group {
                            if case .connection(let stream) = branch { result = stream }
                        }
                        guard let result else { throw CancellationError() }
                        return result
                    }
                    try token.ensureCurrent()
                    let sessionID = await connectionManager.currentSessionID
                    try await coordinator.commit(RealtimeState(connectionState: .connected, sessionID: sessionID), token: token)
                    try await performStartGeneration(context: context, faceRestoration: faceRestoration, token: token, failureScope: .all)
                    return remote
                } catch {
                    timing.finishFailure(error)
                    throw error
                }
            }
        }
    }

    /// Stops the local camera stream and updates media readiness.
    ///
    /// - Throws: An error if realtime is still connected, a conflicting operation exists, or this operation is cancelled.
    func stopLocalCameraStream() async throws {
        try await coordinator.run(
            kind: .media
        ) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Disconnect realtime before stopping the local " +
                    "camera stream"
            )
            token.setFailureScope(.all)
            await mediaController.stopLocalCameraStream()
            try token.ensureCurrent()
            errorHandler.invalidatePendingFailures()
            let hasLocalMedia = await mediaController.currentTrack != nil
            try await coordinator.commit(
                RealtimeState(connectionState: hasLocalMedia ? .ready : .idle), token: token
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
                source: source, videoFormat: videoFormat
            )
            try token.ensureCurrent()
            return stream
        }
    }

    /// Unbinds external input after connection cleanup, preserving caller capture ownership.
    func stopExternalVideoStream() async throws {
        try await coordinator.run(kind: .media) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Disconnect realtime before stopping the external video stream"
            )
            guard await mediaController.isExternalVideo else { return }
            token.setFailureScope(.all)
            await mediaController.stopExternalVideoStream()
            try token.ensureCurrent()
            errorHandler.invalidatePendingFailures()
            let hasLocalMedia = await mediaController.currentTrack != nil
            try await coordinator.commit(
                RealtimeState(connectionState: hasLocalMedia ? .ready : .idle), token: token
            )
        }
    }

    /// Switches the active camera device.
    ///
    /// During generation, the SDK stops generation, switches cameras, and resumes with cached conditions.
    /// The RTC connection is retained. Camera switching is unavailable while connection or generation starts.
    ///
    /// - Returns: The local stream retaining the original video track with its camera position updated.
    /// - Throws: An error if no camera stream exists, realtime startup is in progress, or camera switching or generation recovery
    ///   fails.
    func switchCamera(to deviceID: String) async throws -> RealtimeMediaStream {
        let current = await coordinator.currentState
        guard current.connectionState != .connecting,
              current.connectionState != .disconnecting else {
            throw await reportError(
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while realtime " +
                        "is transitioning"
                )
            )
        }
        guard current.connectionState == .generating ||
                !streamController.hasGenerationTask else {
            throw await reportError(
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while " +
                        "realtime generation is starting"
                )
            )
        }

        return try await coordinator.run(
            kind: .cameraSwitch
        ) { [self] token in
            let current = await coordinator.currentState
            guard current.connectionState != .connecting,
                  current.connectionState != .disconnecting else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while realtime " +
                        "is transitioning"
                )
            }

            let wasGenerating = current.connectionState == .generating
            guard wasGenerating || !streamController.hasGenerationTask else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Camera switching is unavailable while " +
                        "realtime generation is starting"
                )
            }

            if wasGenerating {
                token.setFailureScope(.connection)
                try await generationManager.stop(
                    taskID: current.taskID ?? ""
                )
                try await coordinator.commit(
                    RealtimeState(
                        connectionState: .connected,
                        sessionID: current.sessionID
                    ),
                    token: token
                )
            }

            let stream = try await mediaController.switchCamera(to: deviceID)
            try token.ensureCurrent()
            try await reconcileFrameInterpolation(for: stream)
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
    /// - Returns: The connected remote media stream, which can be bound to a result preview view.
    /// - Throws: An error on invalid local stream, existing connection, conflicting operation, cancellation, or connection failure.
    func connect(
        localStream: RealtimeMediaStream
    ) async throws -> RealtimeMediaStream {
        try await coordinator.run(
            kind: .connection
        ) { [self] token in
            try await performConnect(
                localStream: localStream,
                token: token
            )
        }
    }

    /// Disconnects realtime while retaining the local media preview.
    func disconnect() async {
        await coordinator.disconnect()
    }

    /// Disconnects realtime for a business reason while retaining usable local media.
    ///
    /// - Parameter reason: The disconnect reason, such as a display orientation change.
    func disconnect(reason: RealtimeReason) async {
        await coordinator.disconnect(reason: reason)
    }

    /// Closes the realtime lifecycle and releases the connection, local media, and RTC engine.
    ///
    /// Concurrent close calls await the same cleanup task; local streams can be created again after close completes.
    func close() async {
        await coordinator.terminate(
            .all
        )
    }

    /// Starts generation, or updates current conditions if generation is already active.
    ///
    /// - Parameters:
    ///   - context: The generation conditions; required initially. Later calls may pass `nil` to reuse cached conditions.
    ///   - faceRestoration: Whether to restore the original face; each call sends this setting.
    /// - Throws: An error if conditions are invalid or generation startup or update fails.
    func startGeneration(context: RealtimeContext?, faceRestoration: Bool = false) async throws {
        try await coordinator.run(
            kind: .generation
        ) { [self] token in
            let current = await coordinator.currentState
            try token.ensureCurrent()
            let measuresStartup = current.connectionState == .connected
            if measuresStartup {
                timing.begin(preservingCameraPreparation: !(await mediaController.isExternalVideo))
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
    /// - Returns: The remote media stream for the current RTC connection.
    /// - Throws: An error on invalid local stream, connection failure, or generation startup failure.
    func startGeneration(
        localStream: RealtimeMediaStream,
        context: RealtimeContext?,
        faceRestoration: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await coordinator.run(
            kind: .generation
        ) { [self] token in
            let initialState = await coordinator.currentState
            let hasConnection = await connectionManager.currentSessionID != ""
            try token.ensureCurrent()
            let measuresStartup = initialState.connectionState != .connecting &&
                initialState.connectionState != .disconnecting &&
                initialState.connectionState != .generating
            if measuresStartup {
                timing.begin(preservingCameraPreparation: !(await mediaController.isExternalVideo))
            }
            do {
                guard await mediaController.owns(localStream) else {
                    throw XmaxError(
                        code: .invalidConfiguration,
                        message: "The local stream must be created and " +
                            "started by this realtime manager"
                    )
                }
                try token.ensureCurrent()

                try await generationManager.validateContext(context)
                try token.ensureCurrent()
                let remoteStream: RealtimeMediaStream
                if hasConnection {
                    guard let activeRemoteStream =
                            await connectionManager.currentRemoteStream else {
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
    /// - Throws: An error on unavailable connection, invalid conditions, cancellation, or generation startup or update failure.
    private func performStartGeneration(
        context: RealtimeContext?,
        faceRestoration: Bool,
        token: RealtimeCoordinator.Token,
        failureScope: RealtimeCoordinator.TerminationScope = .connection
    ) async throws {
        try token.ensureCurrent()
        let sessionID = await connectionManager.currentSessionID
        let current = await coordinator.currentState
        guard !sessionID.isEmpty,
              current.connectionState == .connected ||
                current.connectionState == .generating,
              let videoFormat = await mediaController.currentVideoFormat else {
            throw XmaxError(
                code: .rtcError,
                message: "Realtime connection is not open"
            )
        }

        let paddingContain = await mediaController.usesContainPadding
        let generationSize = try paddingContain ? mediaService.resolveGenerationSize(videoFormat.size) : videoFormat.size
        let generationFormat = videoFormat.resized(width: Int(generationSize.width), height: Int(generationSize.height))
        try token.ensureCurrent()

        if current.connectionState == .generating,
           let taskID = current.taskID {
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
            try await renderController.waitUntilRemoteFrameReady()
            try token.ensureCurrent()
            timing.finishFirstFrame(taskID: taskID)
            try streamController.activateRemoteAudio()
            guard await connectionManager.currentSessionID == sessionID else {
                throw XmaxError(
                    code: .cancelled,
                    message: "Realtime connection was cancelled"
                )
            }
            try await coordinator.commit(
                RealtimeState(
                    connectionState: .generating,
                    sessionID: sessionID,
                    taskID: taskID
                ),
                token: token
            )
            try token.ensureCurrent()
            if let quality = streamController.qualityConfiguration {
                streamController.completeQuality(downlink: false, level: quality.uplinkLevel, success: true)
                streamController.completeQuality(downlink: true, level: quality.downlinkLevel, success: true)
            }
            streamController.setAdaptiveQualityListener { [weak self] quality, time in
                Task { await self?.adaptQuality(quality, sampledAt: time, taskID: taskID) }
            }
            timing.finish(taskID: taskID)
        } catch {
            throw error
        }
    }
}

private extension XmaxRealtimeManager {
    /// Calculates return video format from the network tier and interpolation limits.
    ///
    /// - Parameters:
    ///   - baseline: The baseline local media format.
    ///   - level: The target downstream tier in 1...5.
    ///   - interpolation: Whether to apply pixel area limits required by interpolation.
    /// - Returns: The return format preserving media aspect ratio while satisfying tier, interpolation, and four-pixel alignment limits.
    /// - Throws: An error if the baseline format is invalid or no valid return dimensions can be calculated.
    nonisolated func resolveTargetVideoFormat(
        baseline: RealtimeVideoFormat,
        level: Int,
        interpolation: Bool
    ) throws -> RealtimeVideoFormat {
        try baseline.validate()
        let maximumSize = QualityVideoFormat.resolveDownlinkMaximumSize(baseline, level: level)
        let targetSize = try mediaService.resolveTargetSize(
            baseline.size,
            maximumSize: maximumSize,
            frameInterpolationEnabled: interpolation
        )
        let format = QualityVideoFormat.resolve(baseline, level: level, downlink: true)
        return format.resized(width: Int(targetSize.width), height: Int(targetSize.height))
    }

    /// Attempts automatic quality adjustment for the current task's network sample; skips it while busy.
    ///
    /// - Parameters:
    ///   - sample: The upstream and downstream network quality sample.
    ///   - sampledAt: The sample's monotonic system time in seconds.
    ///   - taskID: The generation task identifier associated with the sample.
    func adaptQuality(_ sample: RealtimeNetworkQuality, sampledAt: TimeInterval, taskID: String) async {
        guard !qualityPending else { return }
        qualityPending = true
        defer { qualityPending = false }
        do {
            let accepted = try await coordinator.runAdaptiveConfiguration { [self] token in
                let state = await coordinator.currentState
                try token.ensureCurrent()
                guard state.taskID == taskID, state.connectionState == .generating else { return }
                let change = streamController.proposeQuality(sample, sampledAt: sampledAt)
                if let level = change.uplink {
                    try? await applyQualityLevel(level, downlink: false, taskID: taskID, token: token)
                }
                try token.ensureCurrent()
                if let level = change.downlink {
                    try? await applyQualityLevel(level, downlink: true, taskID: taskID, token: token)
                }
            }
            if !accepted { streamController.resetQualitySamples() }
        } catch {
            // Cancellation and disconnect samples do not belong to a new connection or override its configuration.
            if !Task.isCancelled, await coordinator.currentState.taskID == taskID {
                streamController.resetQualitySamples()
            }
        }
    }

    /// Applies transport configuration in one direction and saves the tier on success.
    ///
    /// - Parameters:
    ///   - level: The target tier in 1...5.
    ///   - downlink: true updates return dimensions; false updates local encoding.
    ///   - taskID: The generation task identifier whose transport configuration is being updated.
    ///   - token: The lifecycle token for this configuration operation.
    /// - Throws: An error on cancellation, unsupported interpolation dimensions, signal failure, or encoding configuration failure.
    func applyQualityLevel(
        _ level: Int,
        downlink: Bool,
        taskID: String,
        token: RealtimeCoordinator.Token
    ) async throws {
        guard let configuration = streamController.qualityConfiguration else { return }
        do {
            try token.ensureCurrent()
            let format: RealtimeVideoFormat
            if downlink {
                let interpolation = await renderController.isFrameInterpolationEnabled
                try token.ensureCurrent()
                format = try resolveTargetVideoFormat(
                    baseline: configuration.baseline,
                    level: level,
                    interpolation: interpolation
                )
                guard !interpolation || mediaService.supportsFrameInterpolation(for: format.size) else {
                    throw XmaxError(
                        code: .frameInterpolationUnsupported,
                        message: "Frame interpolation is unavailable for the target size"
                    )
                }

                if await connectionManager.currentTargetSize != format.size {
                    try token.ensureCurrent()
                    try await streamController.changeTargetSize(
                        taskID: taskID,
                        targetSize: format.size,
                        ensureActive: { try token.ensureCurrent() }
                    )
                    // Synchronizes expected dimensions after sending; disconnect waits for this commit before releasing resources.
                    await connectionManager.updateTargetSize(format.size, videoFormat: configuration.baseline)
                    try await renderController.setFrameInterpolationEnabled(interpolation, videoFormat: format)
                }
            } else {
                format = QualityVideoFormat.resolve(configuration.baseline, level: level, downlink: false)
                try streamController.setVideoEncoderConfig(format)
            }
            try token.ensureCurrent()
            streamController.completeQuality(downlink: downlink, level: level, success: true)
            XmaxLogger.realtime.debug(
                message: "自动调档 (Adaptive Quality)\n" +
                    "└─ \(downlink ? "Downlink" : "Uplink"): L\(level), \(format.width) × \(format.height)"
            )
        } catch {
            guard token.isCurrent else { throw error }
            streamController.completeQuality(downlink: downlink, level: level, success: false)
            XmaxLogger.realtime.warn(message: "自动调档失败 (Adaptive Quality Failed)\n└─ \(ErrorMessageFormatter.format(error))")
            throw error
        }
    }

    /// Publishes local media, establishes a realtime session, and commits the connected state on success.
    ///
    /// - Parameters:
    ///   - localStream: The local media stream created and owned by this manager.
    ///   - token: The lifecycle token for this connection operation.
    /// - Returns: The remote media stream for this session.
    /// - Throws: An error on an existing connection, invalid local stream, cancellation, or session or RTC connection failure.
    func performConnect(
        localStream: RealtimeMediaStream,
        token: RealtimeCoordinator.Token
    ) async throws -> RealtimeMediaStream {
        let current = await coordinator.currentState
        guard await connectionManager.currentSessionID == "",
              current.connectionState != .connecting,
              current.connectionState != .disconnecting else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Realtime connection is already open"
            )
        }
        guard await mediaController.owns(localStream) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "The local stream must be created and started " +
                    "by this realtime manager"
            )
        }

        try token.ensureCurrent()
        guard let videoFormat = localStream.videoTrack?.videoFormat else {
            throw XmaxError(code: .invalidConfiguration, message: "Local video format is unavailable")
        }

        token.setFailureScope(.connection)
        try await generationManager.reset()
        try token.ensureCurrent()
        try await coordinator.commit(
            RealtimeState(connectionState: .connecting),
            token: token
        )
        let quality = streamController.prepareQuality(baseline: videoFormat, model: options.model.rawValue)
        try streamController.setVideoEncoderConfig(quality.uplink)
        let targetSize = try await reconcileFrameInterpolation(for: localStream)
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

        try await coordinator.commit(
            RealtimeState(
                connectionState: .connected,
                sessionID: sessionID
            ),
            token: token
        )
        return remoteStream
    }

    /// Creates local media and configures orientation, initial volume, and media readiness notifications.
    ///
    /// - Parameters:
    ///   - source: The media source being created.
    ///   - prepare: The asynchronous stream creation operation receiving the current lifecycle token.
    /// - Returns: The prepared local stream; camera readiness requires active capture and a bound preview.
    /// - Throws: An error if a local stream or realtime connection exists, or preparation fails or is cancelled.
    func createLocalMediaStream(
        source: RealtimeMediaSource,
        prepare: @escaping @Sendable (RealtimeCoordinator.Token) async throws
            -> RealtimeMediaStream
    ) async throws -> RealtimeMediaStream {
        return try await coordinator.run(
            kind: .media
        ) { [self] token in
            try await ensureLocalMediaCanChange(
                message: "Local \(source.rawValue) stream is unavailable during " +
                    "a realtime connection"
            )
            guard await mediaController.currentTrack == nil else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Stop the current local media stream before creating another one"
                )
            }
            try token.ensureCurrent()
            errorHandler.invalidatePendingFailures()
            try await coordinator.commit(RealtimeState(connectionState: .preparing), token: token)
            try token.ensureCurrent()

            let stream = try await LocalMediaPreparationTiming.measureAsync(.mediaPrepare) {
                try await prepare(token)
            }
            try token.ensureCurrent()
            token.setFailureScope(.all)
            _ = try await LocalMediaPreparationTiming.measureAsync(.interpolationConfiguration) {
                try await reconcileFrameInterpolation(for: stream)
            }
            try token.ensureCurrent()
            try streamController.setRemoteAudioVolume(0)
            if source == .camera {
                await LocalMediaPreparationTiming.measureAsync(.previewReadinessRegistration) {
                    await mediaController.setCameraPreviewReadyHandler { [coordinator] isCurrent in
                        Task {
                            await coordinator.localPreviewDidBecomeReady(isCurrent: isCurrent)
                        }
                    }
                }
            } else {
                try await coordinator.commit(RealtimeState(connectionState: .ready), token: token)
            }
            return stream
        }
    }

    /// Checks that no realtime connection prevents local media changes.
    ///
    /// - Parameter message: The error message when media changes are disallowed.
    /// - Throws: An error if a session exists or connection setup or teardown is in progress.
    func ensureLocalMediaCanChange(message: String) async throws {
        let current = await coordinator.currentState
        guard await connectionManager.currentSessionID == "",
              current.connectionState != .connecting,
              current.connectionState != .disconnecting else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: message
            )
        }
    }

    /// Configures valid return dimensions; disables unsupported interpolation while preserving the media flow.
    ///
    /// - Parameter stream: The current local media stream.
    /// - Returns: Return dimensions based on the network tier and interpolation limits; nil without a video format.
    /// - Throws: An error if the local format cannot produce valid return dimensions aligned to four pixels.
    @discardableResult
    func reconcileFrameInterpolation(
        for stream: RealtimeMediaStream
    ) async throws -> CGSize? {
        guard let videoFormat = stream.videoTrack?.videoFormat else {
            return nil
        }
        return try await reconcileFrameInterpolation(videoFormat: videoFormat)
    }

    func reconcileFrameInterpolation(videoFormat: RealtimeVideoFormat) async throws -> CGSize? {
        let level = streamController.qualityConfiguration?.downlinkLevel ?? 2
        let fallbackFormat = try resolveTargetVideoFormat(baseline: videoFormat, level: level, interpolation: false)
        let interpolation = await renderController.isFrameInterpolationEnabled
        do {
            let targetSize = try resolveTargetVideoFormat(baseline: videoFormat, level: level, interpolation: interpolation).size
            guard !interpolation || mediaService.supportsFrameInterpolation(for: targetSize) else {
                throw XmaxError(
                    code: .frameInterpolationUnsupported,
                    message: "Frame interpolation is unavailable for " +
                        "\(Int(targetSize.width)) × \(Int(targetSize.height)) video"
                )
            }
            try await renderController.setFrameInterpolationEnabled(
                interpolation,
                videoFormat: videoFormat.resized(
                    width: Int(targetSize.width),
                    height: Int(targetSize.height)
                )
            )
            return targetSize
        } catch {
            try? await renderController.setFrameInterpolationEnabled(
                false,
                videoFormat: fallbackFormat
            )
            await errorHandler.report(XmaxError.from(error))
            return fallbackFormat.size
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
        await coordinator.terminate(
            with: error,
            target: .connection
        )
    }

    /// Logs and converts an error into the unified SDK error type.
    ///
    /// - Parameter error: The original error to log and convert.
    /// - Returns: The XmaxError for the caller to throw or handle.
    @discardableResult
    func reportError(_ error: any Error) async -> XmaxError {
        let xmaxError = XmaxError.from(error)
        await errorHandler.report(xmaxError)
        return xmaxError
    }

    /// Checks that volume is finite and within 0...1.
    ///
    /// - Parameter volume: The playback volume to apply.
    /// - Throws: An error if the volume is nonfinite or out of range.
    static func validateAudioVolume(_ volume: Float) throws {
        guard volume.isFinite, (0...1).contains(volume) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Audio volume must be between 0 and 1"
            )
        }
    }

    /// Releases realtime resources in scope and returns the remaining session and local media information.
    ///
    /// - Parameters:
    ///   - scope: The resource scope to release.
    ///   - taskID: The task identifier to stop; an empty string means no specific task.
    ///   - mediaController: The media component stopping capture or restoring local preview.
    ///   - connectionManager: The component releasing RTC rooms and server sessions.
    ///   - generationManager: The component stopping generation and clearing cached conditions.
    /// - Returns: The ended session identifier and whether local media remains usable.
    nonisolated static func cleanup(
        scope: RealtimeCoordinator.TerminationScope,
        taskID: String,
        mediaController: any MediaControlling,
        connectionManager: XmaxRealtimeConnectionManager,
        generationManager: XmaxRealtimeGenerationManager
    ) async -> RealtimeCoordinator.CleanupResult {

        if scope == .all {
            await mediaController.stopLocalCapture()
        }
        do {
            try await mediaController.stopMicrophoneCapture()
        } catch {
            XmaxLogger.realtime.error(
                message: """
                停止麦克风采集失败 (Failed to Stop Microphone Capture)
                └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                """
            )
        }

        do {
            try await generationManager.reset(taskID: taskID)
        } catch {
            XmaxLogger.realtime.error(
                message: """
                停止实时生成失败 (Failed to Stop Realtime Generation)
                └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                """
            )
        }

        let activeSessionID = await connectionManager.currentSessionID
        var sessionID = activeSessionID.isEmpty ? nil : activeSessionID
        do {
            sessionID = try await connectionManager.disconnect() ?? sessionID
        } catch {
            XmaxLogger.realtime.error(
                message: """
                断开实时连接失败 (Failed to Disconnect Realtime)
                └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                """
            )
        }

        if scope == .all {
            await mediaController.stopLocalStream()
        }
        return RealtimeCoordinator.CleanupResult(
            sessionID: sessionID,
            hasLocalMedia: await mediaController.currentTrack != nil
        )
    }
}

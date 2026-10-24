//
//  XmaxRealtimeConnectionManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Checks whether the current connection operation remains valid.
///
/// - Returns: `true` if the connection operation is valid.
typealias RealtimeConnectionValidity = @Sendable () -> Bool

/// Receives heartbeat failures for the specified session.
///
/// - Parameters:
///   - sessionID: The identifier of the session whose heartbeat failed.
///   - error: The session heartbeat error.
typealias RealtimeConnectionHeartbeatFailureHandler =
    @Sendable (
        _ sessionID: String,
        _ error: XmaxError
    ) async -> Void

/// Coordinates server sessions, RTC rooms, local publication, and remote media resources.
actor XmaxRealtimeConnectionManager {

    /// Reports recoverable output configuration failures.
    private let errorManager: XmaxRealtimeErrorManager

    /// The sizing and capability rules used by transport and output configuration.
    private nonisolated let mediaService: any MediaServicing

    /// The service that creates, maintains, and closes server sessions.
    private let sessionService: any RealtimeSessionServicing

    /// The media component that handles interactions from the remote video view.
    private let interactionController: any InteractionControlling

    /// The controller that manages remote video rendering.
    private let renderController: any RenderControlling

    /// The controller that manages RTC connections and local stream publishing.
    private let streamController: any StreamControlling

    /// The recorder for connection startup timings.
    private let timing: RealtimeTiming

    /// The remote video track for the current connection.
    private var activeRemoteTrack: RealtimeVideoTrack?

    /// The server session owned by this connection.
    private var activeSession: RealtimeSession?

    /// The most recently applied target dimensions for server output, in pixels.
    private(set) var currentTargetSize: CGSize?

    /// Creates a realtime connection manager.
    init(
        sessionService: any RealtimeSessionServicing,
        interactionController: any InteractionControlling,
        renderController: any RenderControlling,
        streamController: any StreamControlling,
        timing: RealtimeTiming = RealtimeTiming(),
        mediaService: any MediaServicing = MediaService(),
        errorManager: XmaxRealtimeErrorManager = XmaxRealtimeErrorManager()
    ) {
        self.mediaService = mediaService
        self.errorManager = errorManager
        self.sessionService = sessionService
        self.interactionController = interactionController
        self.renderController = renderController
        self.streamController = streamController
        self.timing = timing
    }

    /// The current session identifier; an empty string if no session is active.
    var currentSessionID: String {
        activeSession?.id ?? ""
    }

    /// The connected remote media stream, or `nil` before its session and tracks are ready.
    var currentRemoteStream: RealtimeMediaStream? {
        guard activeSession != nil, let activeRemoteTrack else {
            return nil
        }
        return RealtimeMediaStream(
            id: StreamID.remote.rawValue,
            videoTrack: activeRemoteTrack
        )
    }

    /// Updates remote track and render formats using the current return dimensions.
    ///
    /// - Parameter videoFormat: The generation video format; return dimensions override the track dimensions when
    ///   configured.
    func updateRemoteVideoFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async {
        guard let activeRemoteTrack else { return }
        let remoteFormat = remoteVideoFormat(for: videoFormat)
        activeRemoteTrack.updateVideoFormat(remoteFormat)
        await renderController.updateRemoteVideoFormat(
            remoteFormat,
            for: activeRemoteTrack
        )
    }

    /// Stores return dimensions for the current connection and updates the remote render format.
    ///
    /// - Parameters:
    ///   - size: The target server return video dimensions in pixels.
    ///   - videoFormat: The generation video format used to preserve frame rate and other non-size settings.
    func updateTargetSize(
        _ size: CGSize,
        videoFormat: RealtimeVideoFormat
    ) async {
        guard activeSession != nil else { return }
        currentTargetSize = size
        await updateRemoteVideoFormat(videoFormat)
    }

    /// Creates a server session, joins RTC, publishes local streams, and returns the registered remote stream.
    ///
    /// - Parameters:
    ///   - model: The generation model for this session.
    ///   - videoFormat: The generation video format used to initialize remote tracks.
    ///   - targetSize: The return video dimensions; `nil` uses generation dimensions.
    ///   - includeLocalAudio: Whether to publish local audio.
    ///   - isCurrent: The callback checking connection operation validity.
    ///   - onHeartbeatFailure: The callback receiving heartbeat errors for the current session.
    ///
    /// - Returns: The remote stream with rendering and interaction registered; availability awaits first-frame
    ///   confirmation.
    ///
    /// - Throws: An error on session creation, RTC join, or local publication failure, or connection cancellation.
    func connect(
        model: RealtimeModel,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        includeLocalAudio: Bool,
        isCurrent: @escaping RealtimeConnectionValidity,
        onHeartbeatFailure: @escaping RealtimeConnectionHeartbeatFailureHandler
    ) async throws -> RealtimeMediaStream {
        currentTargetSize = targetSize
        var session: RealtimeSession?
        var sessionActivated = false

        do {
            timing.beginSessionCreation()
            session = try await sessionService.createSession(model: model)
            timing.finishSessionCreation()
            try Self.ensureCurrent(isCurrent)
            guard let session,
                let connection = session.connection
            else {
                throw XmaxError(
                    code: .sessionError,
                    message: "Session does not contain complete RTC join " + "information"
                )
            }

            try await streamController.connect(
                connection: connection,
                includeLocalAudio: includeLocalAudio,
                ensureActive: {
                    try Self.ensureCurrent(isCurrent)
                }
            )
            try Self.ensureCurrent(isCurrent)

            sessionService.startHeartbeat(
                sessionID: session.id,
                onFailure: onHeartbeatFailure
            )
            let remoteTrack = RealtimeVideoTrack(
                id: connection.botName ?? "video-remote",
                videoFormat: remoteVideoFormat(for: videoFormat)
            )
            await registerRemoteTrack(remoteTrack)

            activeSession = session
            activeRemoteTrack = remoteTrack
            sessionActivated = true
            try Self.ensureCurrent(isCurrent)

            return RealtimeMediaStream(
                id: StreamID.remote.rawValue,
                videoTrack: remoteTrack
            )
        } catch {
            if isCurrent() {
                await rollbackConnection()
            }

            if let session, !sessionActivated {
                await closeSessionAfterFailedConnection(session.id)
            }
            guard isCurrent() else {
                throw XmaxError(
                    code: .cancelled,
                    message: "Realtime connection was cancelled"
                )
            }
            throw XmaxError.from(error)
        }
    }

    /// Disconnects RTC, releases remote render resources, and closes the server session.
    ///
    /// - Returns: The closed session identifier, or `nil` if none was active.
    ///
    /// - Throws: An error if closing the server session fails.
    @discardableResult
    func disconnect() async throws -> String? {
        let session = activeSession
        let remoteTrack = activeRemoteTrack
        activeSession = nil
        activeRemoteTrack = nil
        currentTargetSize = nil

        sessionService.stopHeartbeat()
        await resetRemoteRendering(track: remoteTrack)
        await streamController.disconnect()

        let sessionID = session?.id
        if let sessionID {
            try await sessionService.closeSession(sessionID: sessionID)
        }
        return sessionID
    }
}

extension XmaxRealtimeConnectionManager {

    /// Prepares initial transport tiers and return dimensions from the local media baseline.
    ///
    /// - Parameters:
    ///   - baseline: The negotiated local video format.
    ///   - options: The configuration containing the model's input limits.
    ///   - ensureCurrent: The callback checking operation validity.
    ///
    /// - Returns: The initial quality configuration and resolved return dimensions.
    ///
    /// - Throws: An error if encoding configuration fails or the operation is invalidated.
    func prepareQuality(
        baseline: RealtimeVideoFormat,
        options: RealtimeConfiguration,
        ensureCurrent: @Sendable () throws -> Void
    ) async throws -> (configuration: QualityConfiguration, targetSize: CGSize?) {
        try ensureCurrent()
        let quality = streamController.prepareQuality(
            baseline: baseline,
            model: options.model.rawValue,
            isAdaptiveQualityEnabled: options.isAdaptiveQualityEnabled
        )
        try streamController.setVideoEncoderConfig(quality.uplink)
        let targetSize = try await reconcileFrameInterpolation(for: baseline)
        try ensureCurrent()
        return (quality, targetSize)
    }

    /// Records the initial transport tiers only after generation is ready.
    func completeInitialQuality() {
        guard let quality = streamController.qualityConfiguration else { return }
        streamController.completeQuality(
            downlink: false,
            level: quality.uplinkLevel,
            success: true
        )
        streamController.completeQuality(
            downlink: true,
            level: quality.downlinkLevel,
            success: true
        )
    }

    /// Resolves downlink dimensions within quality and interpolation limits.
    ///
    /// - Parameters:
    ///   - baseline: The negotiated local video format.
    ///   - level: The downstream quality tier in `1...5`.
    ///   - interpolation: Whether to apply interpolation pixel limits.
    ///
    /// - Returns: The format preserving aspect ratio within the tier and four-pixel alignment limits.
    ///
    /// - Throws: An error if the baseline is invalid or no valid return dimensions can be calculated.
    nonisolated func resolveTargetVideoFormat(
        baseline: RealtimeVideoFormat,
        level: Int,
        interpolation: Bool
    ) throws -> RealtimeVideoFormat {
        try baseline.validate()
        let maximumSize = QualityVideoFormat.resolveDownlinkMaximumSize(
            baseline,
            level: level
        )
        let targetSize = try mediaService.resolveTargetSize(
            baseline.size,
            maximumSize: maximumSize,
            frameInterpolationEnabled: interpolation
        )
        let format = QualityVideoFormat.resolve(
            baseline,
            level: level,
            downlink: true
        )
        return format.resized(
            width: Int(targetSize.width),
            height: Int(targetSize.height)
        )
    }

    /// Applies encoding or return dimensions and records the tier change outcome.
    ///
    /// - Parameters:
    ///   - level: The target tier in `1...5`.
    ///   - downlink: Whether to update return dimensions rather than local encoding.
    ///   - taskID: The generation task whose transport configuration is being updated.
    ///   - ensureCurrent: The callback checking operation validity.
    ///
    /// - Throws: An error on cancellation, unsupported interpolation dimensions, signaling, or encoding failure.
    func applyQualityLevel(
        _ level: Int,
        downlink: Bool,
        taskID: String,
        ensureCurrent: @escaping @Sendable () throws -> Void
    ) async throws {
        guard let configuration = streamController.qualityConfiguration else { return }
        do {
            try ensureCurrent()
            let format: RealtimeVideoFormat
            if downlink {
                let interpolation = await renderController.isFrameInterpolationEnabled
                try ensureCurrent()
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

                if currentTargetSize != format.size {
                    try ensureCurrent()
                    try await streamController.changeTargetSize(
                        taskID: taskID,
                        targetSize: format.size,
                        ensureActive: { try ensureCurrent() }
                    )
                    // Synchronizes expected dimensions after sending; disconnect waits for this commit before releasing resources.
                    await updateTargetSize(
                        format.size,
                        videoFormat: configuration.baseline
                    )
                    try await renderController.setFrameInterpolationEnabled(
                        interpolation,
                        videoFormat: format
                    )
                }
            } else {
                format = QualityVideoFormat.resolve(
                    configuration.baseline,
                    level: level,
                    downlink: false,
                    minimumInputPixels: configuration.minimumInputPixels
                )
                try streamController.setVideoEncoderConfig(format)
            }
            try ensureCurrent()
            streamController.completeQuality(
                downlink: downlink,
                level: level,
                success: true
            )
            XmaxLogger.realtime.debug(
                message: "自动调档 (Adaptive Quality)\n"
                    + "└─ \(downlink ? "Downlink" : "Uplink"): L\(level), \(format.width) × \(format.height)"
            )
        } catch {
            guard (try? ensureCurrent()) != nil else { throw error }
            streamController.completeQuality(
                downlink: downlink,
                level: level,
                success: false
            )
            XmaxLogger.realtime.warn(
                message: "自动调档失败 (Adaptive Quality Failed)\n└─ \(ErrorMessageFormatter.format(error))"
            )
            throw error
        }
    }

    /// Applies return dimensions and interpolation within an admitted lifecycle operation.
    ///
    /// - Parameters:
    ///   - enabled: Whether to interpolate remote video frames.
    ///   - mediaFormat: The local media format; `nil` configures rendering without return dimensions.
    ///   - taskID: The active generation task; `nil` omits the return-dimension signal.
    ///   - ensureCurrent: The callback checking operation validity.
    ///
    /// - Throws: An error on invalid dimensions, unsupported interpolation, cancellation, or signaling failure.
    func setFrameInterpolationEnabled(
        _ enabled: Bool,
        mediaFormat: RealtimeVideoFormat?,
        taskID: String?,
        ensureCurrent: @escaping @Sendable () throws -> Void
    ) async throws {
        do {
            let targetSize = try mediaFormat.map {
                try resolveTargetVideoFormat(
                    baseline: $0,
                    level: streamController.qualityConfiguration?.downlinkLevel ?? 2,
                    interpolation: enabled
                ).size
            }
            if enabled, let targetSize,
                !mediaService.supportsFrameInterpolation(for: targetSize)
            {
                throw XmaxError(
                    code: .frameInterpolationUnsupported,
                    message: "Frame interpolation is unavailable for "
                        + "\(Int(targetSize.width)) × \(Int(targetSize.height)) video"
                )
            }
            try ensureCurrent()
            if let taskID, let targetSize,
                currentTargetSize != targetSize
            {
                try await streamController.changeTargetSize(
                    taskID: taskID,
                    targetSize: targetSize,
                    ensureActive: { try ensureCurrent() }
                )
            }

            // Commits local configuration after sending the signal; concurrent disconnect waits for this operation before cleanup.
            if let mediaFormat, let targetSize {
                await updateTargetSize(
                    targetSize,
                    videoFormat: mediaFormat
                )
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

    /// Reconciles return dimensions, falling back to ordinary rendering if interpolation is unsupported.
    ///
    /// - Parameter videoFormat: The local media format; `nil` leaves rendering unchanged.
    ///
    /// - Returns: The resolved return dimensions, or `nil` when no local format is available.
    ///
    /// - Throws: An error if valid fallback dimensions cannot be calculated.
    @discardableResult
    func reconcileFrameInterpolation(
        for videoFormat: RealtimeVideoFormat?
    ) async throws -> CGSize? {
        guard let videoFormat else { return nil }
        let level = streamController.qualityConfiguration?.downlinkLevel ?? 2
        let fallbackFormat = try resolveTargetVideoFormat(
            baseline: videoFormat,
            level: level,
            interpolation: false
        )
        let interpolation = await renderController.isFrameInterpolationEnabled
        do {
            let targetSize = try resolveTargetVideoFormat(
                baseline: videoFormat,
                level: level,
                interpolation: interpolation
            ).size
            guard !interpolation || mediaService.supportsFrameInterpolation(for: targetSize) else {
                throw XmaxError(
                    code: .frameInterpolationUnsupported,
                    message: "Frame interpolation is unavailable for "
                        + "\(Int(targetSize.width)) × \(Int(targetSize.height)) video"
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
            await errorManager.report(XmaxError.from(error))
            return fallbackFormat.size
        }
    }
}

private extension XmaxRealtimeConnectionManager {

    /// Applies current return dimensions to the generation video format.
    ///
    /// - Parameter generationFormat: The generation video format.
    ///
    /// - Returns: The format using return dimensions, or the original format when no return dimensions are set.
    func remoteVideoFormat(
        for generationFormat: RealtimeVideoFormat
    ) -> RealtimeVideoFormat {
        guard let currentTargetSize else { return generationFormat }
        return generationFormat.resized(
            width: Int(currentTargetSize.width),
            height: Int(currentTargetSize.height)
        )
    }

    /// Checks that the connection operation belongs to the current lifecycle.
    ///
    /// - Parameter isCurrent: The callback reporting connection operation validity.
    ///
    /// - Throws: Cancellation if the connection operation is no longer valid.
    static func ensureCurrent(
        _ isCurrent: RealtimeConnectionValidity
    ) throws {
        guard isCurrent() else {
            throw XmaxError(
                code: .cancelled,
                message: "Realtime connection was cancelled"
            )
        }
    }

    /// Registers remote track rendering and forwards view interactions to the media interaction component.
    ///
    /// - Parameter track: The remote video track to register.
    func registerRemoteTrack(
        _ track: RealtimeVideoTrack
    ) async {
        let interactionController = interactionController
        await renderController.registerRemoteTrack(
            track,
            interactionListener: { frame in
                await interactionController.submitInteraction(frame)
            }
        )
    }

    /// Clears local connection state, stops heartbeats, and releases remote rendering and RTC resources.
    func rollbackConnection() async {
        let remoteTrack = activeRemoteTrack
        activeSession = nil
        activeRemoteTrack = nil
        currentTargetSize = nil

        sessionService.stopHeartbeat()
        await resetRemoteRendering(track: remoteTrack)
        await streamController.disconnect()
    }

    /// Releases remote track render resources and logs failures.
    ///
    /// - Parameter track: The remote track to reset; `nil` clears render state without a bound track.
    func resetRemoteRendering(
        track: RealtimeVideoTrack?
    ) async {
        do {
            try await renderController.resetRemoteTrack(track)
        } catch {
            XmaxLogger.realtime.error(
                message: """
                    重置远端视频渲染失败 (Failed to Reset Remote Video Rendering)
                    └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                    """
            )
        }
    }

    /// Closes a server session whose connection failed and logs any close failure.
    ///
    /// - Parameter sessionID: The session identifier to close.
    func closeSessionAfterFailedConnection(
        _ sessionID: String
    ) async {
        do {
            try await sessionService.closeSession(sessionID: sessionID)
        } catch {
            XmaxLogger.realtime.error(
                message: """
                    连接回滚关闭会话失败 (Failed to Close Session During Connection Rollback)
                    └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                    """
            )
        }
    }
}

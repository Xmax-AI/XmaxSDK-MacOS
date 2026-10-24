//
//  XmaxRealtimeConnectionManager.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
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
typealias RealtimeConnectionHeartbeatFailureHandler = @Sendable (
    _ sessionID: String,
    _ error: XmaxError
) async -> Void

/// Coordinates server sessions, RTC rooms, local publication, and remote media resources.
actor XmaxRealtimeConnectionManager {

    /// Service components
    private let sessionService: any RealtimeSessionServicing

    /// Media components
    private let interactionController: any InteractionControlling

    /// Rendering components
    private let renderController: any RenderControlling

    /// Transport components
    private let streamController: any StreamControlling

    /// Timing metrics
    private let timing: RealtimeTiming

    /// Connection resources
    private var activeRemoteTrack: RealtimeVideoTrack?
    private var activeSession: RealtimeSession?
    private(set) var currentTargetSize: CGSize?

    /// Creates a realtime connection manager.
    ///
    /// - Parameters:
    ///   - sessionService: The service that creates, maintains, and closes server sessions.
    ///   - interactionController: The media component receiving interactions from remote render views.
    ///   - renderController: The component managing remote track rendering.
    ///   - streamController: The component managing RTC connections and local stream publication.
    ///   - timing: The component recording connection startup timings.
    init(
        sessionService: any RealtimeSessionServicing,
        interactionController: any InteractionControlling,
        renderController: any RenderControlling,
        streamController: any StreamControlling,
        timing: RealtimeTiming = RealtimeTiming()
    ) {
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
    /// - Parameter videoFormat: The generation video format; return dimensions override the track dimensions when configured.
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
    /// - Returns: The remote stream with rendering and interaction registered; availability awaits first-frame confirmation.
    /// - Throws: An error on session creation, RTC join, or local publication failure, or connection cancellation.
    func connect(
        model: RealtimeModel,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        includeLocalAudio: Bool,
        beforePublication: @escaping @Sendable () async throws -> Void = {},
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
                  let connection = session.connection else {
                throw XmaxError(
                    code: .sessionError,
                    message: "Session does not contain complete RTC join " +
                        "information"
                )
            }

            try await streamController.connect(
                connection: connection,
                includeLocalAudio: includeLocalAudio,
                beforePublication: beforePublication,
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

private extension XmaxRealtimeConnectionManager {
    /// Applies current return dimensions to the generation video format.
    ///
    /// - Parameter generationFormat: The generation video format.
    /// - Returns: The format using return dimensions, or the original format when no return dimensions are set.
    func remoteVideoFormat(for generationFormat: RealtimeVideoFormat) -> RealtimeVideoFormat {
        guard let currentTargetSize else { return generationFormat }
        return generationFormat.resized(
            width: Int(currentTargetSize.width),
            height: Int(currentTargetSize.height)
        )
    }

    /// Checks that the connection operation belongs to the current lifecycle.
    ///
    /// - Parameter isCurrent: The callback reporting connection operation validity.
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
    func registerRemoteTrack(_ track: RealtimeVideoTrack) async {
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
    func resetRemoteRendering(track: RealtimeVideoTrack?) async {
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
    func closeSessionAfterFailedConnection(_ sessionID: String) async {
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

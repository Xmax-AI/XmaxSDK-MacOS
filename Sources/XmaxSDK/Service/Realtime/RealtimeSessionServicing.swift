//
//  RealtimeSessionServicing.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Defines realtime session API and heartbeat lifecycle capabilities.
protocol RealtimeSessionServicing: Sendable {

    /// Creates a model session and parses RTC join information.
    ///
    /// - Parameter model: The realtime generation model for this session.
    ///
    /// - Returns: The server-created session and RTC connection information.
    ///
    /// - Throws: An error on request failure, missing response fields, or cancellation.
    func createSession(
        model: RealtimeModel
    ) async throws -> RealtimeSession

    /// Starts periodic heartbeats for the specified session, replacing the previous heartbeat task.
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier to keep alive.
    ///   - onFailure: The callback receiving session identity and error on heartbeat failure.
    func startHeartbeat(
        sessionID: String,
        onFailure: @escaping RealtimeSessionHeartbeatFailureHandler
    )

    /// Stops the heartbeat and invalidates pending failure notifications.
    func stopHeartbeat()

    /// Closes the specified server session.
    ///
    /// - Parameter sessionID: The session identifier to close.
    ///
    /// - Throws: An error on close request failure or cancellation.
    func closeSession(
        sessionID: String
    ) async throws
}

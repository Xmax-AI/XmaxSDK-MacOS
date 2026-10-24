//
//  RealtimeState.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Realtime business connection state.
public enum RealtimeConnectionState: String, CaseIterable, Sendable {

    /// No local media stream is available.
    case idle = "Idle"

    /// Preparing local media; cameras also require a valid frame and bound preview.
    case preparing = "Preparing"

    /// Local media is ready for preview, connection, and generation.
    case ready = "Ready"

    /// Creating a session, joining the room, and publishing local streams.
    case connecting = "Connecting"

    /// Realtime is connected with no generation task.
    case connected = "Connected"

    /// Realtime is connected and generation is running.
    case generating = "Generating"

    /// Cleaning up generation, room, and session resources.
    case disconnecting = "Disconnecting"

}

/// The reason for entering the current realtime state.
public enum RealtimeReason: Equatable, Sendable {

    /// Explicit stop or normal resource release.
    case normal

    /// Display orientation changed and generation requires reconfiguration.
    case orientationChanged

    /// An operation or runtime failure ended the current flow.
    case failure(XmaxError)
}

/// The current realtime business state snapshot.
public struct RealtimeState: Equatable, Sendable {

    /// The current connection lifecycle state.
    public let connectionState: RealtimeConnectionState

    /// The current or most recent realtime session identifier.
    public let sessionID: String?

    /// The current generation task identifier.
    public let taskID: String?

    /// The reason for the current state; cleared when starting a new operation normally.
    public let reason: RealtimeReason?

    /// Creates a realtime state snapshot.
    public init(
        connectionState: RealtimeConnectionState,
        sessionID: String? = nil,
        taskID: String? = nil,
        reason: RealtimeReason? = nil
    ) {
        self.connectionState = connectionState
        self.sessionID = sessionID
        self.taskID = taskID
        self.reason = reason
    }
}

/// The realtime state listener.
public typealias RealtimeStateListener =
    @MainActor @Sendable (
        RealtimeState
    ) -> Void

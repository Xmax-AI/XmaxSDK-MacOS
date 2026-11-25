//
//  RealtimeHeartbeat.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Receives the session identifier immediately before an HTTP session heartbeat send attempt.
///
/// Runs synchronously on the request's sending task. Return promptly and dispatch UI or blocking work separately.
public typealias RealtimeHeartbeatListener = @Sendable (_ sessionID: String) -> Void

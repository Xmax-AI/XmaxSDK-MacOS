//
//  RealtimeSessionServicingStub.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@testable import XmaxSDK

enum RealtimeSessionServicingCall: Equatable {
    case createSession(RealtimeModel)
    case startHeartbeat(String)
    case stopHeartbeat
    case closeSession(String)
}

final class RealtimeSessionServicingStub: RealtimeSessionServicing,
    @unchecked Sendable {

    /// Test configuration
    private let session: RealtimeSession
    private let createError: (any Error)?
    private let closeError: (any Error)?
    private let createHandler: (@Sendable () async throws -> Void)?

    /// Concurrent state
    private let lock = NSLock()
    private var storedCalls: [RealtimeSessionServicingCall] = []
    private var heartbeatFailureHandler:
        RealtimeSessionHeartbeatFailureHandler?

    init(
        session: RealtimeSession,
        createError: (any Error)? = nil,
        closeError: (any Error)? = nil,
        createHandler: (@Sendable () async throws -> Void)? = nil
    ) {
        self.session = session
        self.createError = createError
        self.closeError = closeError
        self.createHandler = createHandler
    }

    var calls: [RealtimeSessionServicingCall] {
        lock.withLock { storedCalls }
    }

    func createSession(model: RealtimeModel) async throws -> RealtimeSession {
        let result = try lock.withLock {
            storedCalls.append(.createSession(model))
            if let createError {
                throw createError
            }
            return session
        }
        try await createHandler?()
        return result
    }

    func startHeartbeat(
        sessionID: String,
        onFailure: @escaping RealtimeSessionHeartbeatFailureHandler
    ) {
        lock.withLock {
            storedCalls.append(.startHeartbeat(sessionID))
            heartbeatFailureHandler = onFailure
        }
    }

    func stopHeartbeat() {
        lock.withLock {
            storedCalls.append(.stopHeartbeat)
            heartbeatFailureHandler = nil
        }
    }

    func closeSession(sessionID: String) async throws {
        try lock.withLock {
            storedCalls.append(.closeSession(sessionID))
            if let closeError {
                throw closeError
            }
        }
    }

    func failHeartbeat(
        sessionID: String,
        error: XmaxError
    ) async {
        let handler = lock.withLock { heartbeatFailureHandler }
        await handler?(sessionID, error)
    }
}

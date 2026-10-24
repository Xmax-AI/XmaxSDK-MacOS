//
//  RealtimeErrorHandler.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Logs realtime errors and forwards background failures to the coordinator for lifecycle termination.
final class RealtimeErrorHandler: @unchecked Sendable {

    /// Receives runtime errors, cleanup scope, and a validity callback to terminate the corresponding lifecycle.
    typealias FailureHandler = @Sendable (
        XmaxError, RealtimeCoordinator.TerminationScope, @escaping @Sendable () -> Bool
    ) async -> Void

    /// Concurrency control
    private let lock = NSLock()

    /// Failure lifecycle
    private var mediaRevision = UUID()
    private var connectionRevision = UUID()

    /// Internal failure handling
    private var failureHandler: FailureHandler?

    /// Sets the runtime failure termination callback.
    ///
    /// - Parameter handler: The callback receiving the error, cleanup scope, and lifecycle validity check.
    func setFailureHandler(_ handler: @escaping FailureHandler) {
        lock.withLock { failureHandler = handler }
    }

    /// Invalidates unhandled failures from a completed lifecycle.
    ///
    /// - Parameter target: The cleaned resource scope; connection cleanup invalidates connection failures, while full cleanup also invalidates media failures.
    func invalidatePendingFailures(target: RealtimeCoordinator.TerminationScope = .all) {
        guard target != .generation else { return }
        lock.withLock {
            connectionRevision = UUID()
            if target == .all { mediaRevision = UUID() }
        }
    }

    /// Forwards runtime failures asynchronously; only logs when no cleanup scope or handler is supplied.
    ///
    /// - Parameters:
    ///   - error: The runtime error to handle.
    ///   - target: The affected resource scope; `nil` leaves the lifecycle running.
    func forward(
        _ error: XmaxError,
        target: RealtimeCoordinator.TerminationScope? = nil
    ) {
        let (revision, handler) = lock.withLock {
            (target == .all ? mediaRevision : connectionRevision, failureHandler)
        }
        Task { [self] in
            guard let target, let handler else {
                await report(error)
                return
            }
            await handler(error, target, { [weak self] in
                guard let self else { return false }
                return lock.withLock {
                    (target == .all ? mediaRevision : connectionRevision) == revision
                }
            })
        }
    }

    /// Logs the code and message of a realtime error.
    ///
    /// - Parameter error: The SDK error to log.
    func report(_ error: XmaxError) async {
        XmaxLogger.realtime.error(
            message: "实时服务错误 (Realtime Service Error)\n" +
                "├─ \(XmaxLogger.localized("错误码：", "Error Code: "))\(error.code.rawValue)\n" +
                "└─ \(XmaxLogger.localized("信息：", "Message: "))\(error.message)"
        )
    }
}

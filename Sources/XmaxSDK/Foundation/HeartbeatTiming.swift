//
//  HeartbeatTiming.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Wraps the asynchronous wait strategy before each heartbeat.
struct HeartbeatSleeper: Sendable {

    /// The cancellable heartbeat wait.
    let sleep: @Sendable () async throws -> Void

    /// A heartbeat wait using a 10-second interval.
    static let live = HeartbeatSleeper {
        try await Task.sleep(for: .seconds(10))
    }
}

/// Uses a version counter to invalidate late results from stopped heartbeats.
final class HeartbeatVersion: @unchecked Sendable {

    /// The lock protecting heartbeat revision updates.
    private let lock = NSLock()

    /// The current heartbeat revision.
    private var value: UInt64 = 0

    /// Advances the heartbeat version, invalidating earlier results.
    ///
    /// - Returns: The updated version.
    @discardableResult
    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    /// Checks whether a heartbeat version belongs to the current lifecycle.
    ///
    /// - Parameter version: The heartbeat version to check.
    ///
    /// - Returns: `true` if it matches the current version.
    func isCurrent(
        _ version: UInt64
    ) -> Bool {
        lock.withLock { value == version }
    }

    /// Advances the version only if still valid, invalidating that heartbeat.
    ///
    /// - Parameter version: The heartbeat version to invalidate.
    ///
    /// - Returns: `true` if the current version was invalidated; `false` for stale versions.
    func invalidate(
        _ version: UInt64
    ) -> Bool {
        lock.withLock {
            guard value == version else {
                return false
            }
            value &+= 1
            return true
        }
    }
}

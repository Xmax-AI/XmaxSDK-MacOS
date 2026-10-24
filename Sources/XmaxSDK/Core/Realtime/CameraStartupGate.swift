//
//  CameraStartupGate.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Lets RTC joining proceed independently, while publication waits for usable local capture.
/// Waiters are cancellation-aware so a failed sibling cannot strand a startup task group.
actor CameraStartupGate {

    /// Whether local capture is usable for publication.
    private var isReady = false

    /// The suspended publication branches, keyed by cancellation identity.
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    /// Marks capture as ready and releases all publication waiters.
    func ready() {
        isReady = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    /// Waits for capture readiness or task cancellation.
    func wait() async throws {
        try Task.checkCancellation()
        if isReady { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
    }

    /// Removes a waiter and resumes it with cancellation.
    private func cancel(
        _ id: UUID
    ) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

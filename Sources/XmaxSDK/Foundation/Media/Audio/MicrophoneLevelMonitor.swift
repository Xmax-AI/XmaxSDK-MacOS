//
//  MicrophoneLevelMonitor.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Coalesces microphone readings and rejects queued delivery from replaced listeners or capture sources.
final class MicrophoneLevelMonitor: @unchecked Sendable {

    /// Protects capture identity, the latest reading, and main-actor delivery admission.
    private let lock = NSLock()

    /// The current application receiver, invoked only on the main actor outside the lock.
    private var listener: RealtimeMicrophoneLevelListener?

    /// The physical capture identity accepted by native observation callbacks.
    private var captureID: UUID?

    /// The latest finite, normalized input reading, or nil without usable input.
    private var level: Float?

    /// Rejects delivery queued before a listener replacement or capture reset.
    private var revision: UInt64 = 0

    /// Keeps pending native readings bounded to one main-actor delivery task per revision.
    private var deliveryQueued = false

    /// Preserves an input-clear event even if fresh audio arrives before main-actor delivery.
    private var clearPending = false

    /// Whether physical microphone capture currently accepts input readings.
    var isCapturing: Bool { lock.withLock { captureID != nil } }

    /// Replaces the receiver and synchronously replays the latest reading on the main actor.
    @MainActor
    func setListener(
        _ listener: RealtimeMicrophoneLevelListener?
    ) {
        let snapshot = lock.withLock {
            revision &+= 1
            deliveryQueued = false
            clearPending = false
            self.listener = listener
            if listener == nil { level = nil }
            return level
        }
        listener?(snapshot)
    }

    /// Starts a fresh capture identity and clears any reading from the previous input.
    func beginCapture() {
        replaceCapture(with: UUID())
    }

    /// Invalidates physical capture callbacks and clears the displayed reading.
    func endCapture() {
        replaceCapture(with: nil)
    }

    /// Binds native readings to the current physical source only while an application observes them.
    func sourceListener() -> RtcMicrophoneLevelListener? {
        let source = lock.withLock { () -> (UUID, UInt64)? in
            guard listener != nil, let captureID else { return nil }
            return (captureID, revision)
        }
        guard let (source, revision) = source else { return nil }
        return { [weak self] value in
            self?.receive(
                value,
                from: source,
                revision: revision
            )
        }
    }

    /// Replaces the capture epoch while preserving a distinct clear before any subsequent reading.
    private func replaceCapture(
        with captureID: UUID?
    ) {
        let delivery = lock.withLock { () -> UInt64? in
            revision &+= 1
            self.captureID = captureID
            level = nil
            clearPending = true
            deliveryQueued = listener != nil
            return deliveryQueued ? revision : nil
        }
        if let delivery { enqueue(revision: delivery) }
    }

    /// Retains only the newest finite sample from the current capture source.
    private func receive(
        _ value: Float?,
        from source: UUID,
        revision: UInt64
    ) {
        if let value, !value.isFinite { return }
        let delivery = lock.withLock { () -> UInt64? in
            guard captureID == source, self.revision == revision, listener != nil else { return nil }
            level = value.map { min(1, max(0, $0)) }
            if value == nil { clearPending = true }
            guard !deliveryQueued else { return nil }
            deliveryQueued = true
            return revision
        }
        if let delivery { enqueue(revision: delivery) }
    }

    /// Schedules delivery without retaining native callbacks or waiting for the main actor.
    private func enqueue(
        revision: UInt64
    ) {
        Task { @MainActor [weak self] in
            self?.deliver(revision: revision)
        }
    }

    /// Drains the current clear and latest reading, ignoring superseded pending work.
    @MainActor
    private func deliver(
        revision: UInt64
    ) {
        let snapshot = lock.withLock { () -> (clear: Bool, level: Float?)? in
            guard self.revision == revision else { return nil }
            deliveryQueued = false
            let snapshot = (clearPending, level)
            clearPending = false
            return snapshot
        }
        guard let snapshot else { return }
        if snapshot.clear {
            notify(
                nil,
                revision: revision
            )
        }
        if snapshot.level != nil || !snapshot.clear {
            notify(
                snapshot.level,
                revision: revision
            )
        }
    }

    /// Rechecks listener validity immediately before invoking user code outside the lock.
    @MainActor
    private func notify(
        _ value: Float?,
        revision: UInt64
    ) {
        let callback = lock.withLock { self.revision == revision ? listener : nil }
        callback?(value)
    }
}

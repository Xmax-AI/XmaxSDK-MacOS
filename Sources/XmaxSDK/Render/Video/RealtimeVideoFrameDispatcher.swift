//
//  RealtimeVideoFrameDispatcher.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Dispatches final remote frames to callers on a separate serial queue.
final class RealtimeVideoFrameDispatcher: @unchecked Sendable {

    /// Stores the frame listener and validity version for pending frames.
    private struct State {

        /// The current final remote video frame receiver.
        var listener: RealtimeVideoFrameListener?

        /// The revision rejecting queued delivery to a replaced listener.
        var version = 0
    }

    /// The lock protecting listener state and its revision.
    private let stateLock = NSLock()

    /// The listener state protected by the state lock.
    private var state = State()

    /// The serial background queue delivering final remote video frames.
    private let deliveryQueue = DispatchQueue(
        label: "ai.xmax.sdk.remote-video-frame",
        qos: .userInitiated
    )

    /// Sets the final video frame listener and invalidates queued frames for the previous listener.
    ///
    /// - Parameter listener: The final frame callback; `nil` stops callbacks.
    func setListener(
        _ listener: RealtimeVideoFrameListener?
    ) {
        stateLock.withLock {
            state.version += 1
            state.listener = listener
        }
    }

    /// Invalidates remote frames already queued but not yet delivered.
    func invalidatePendingFrames() {
        stateLock.withLock {
            state.version += 1
        }
    }

    /// Delivers final video frames in arrival order on a separate serial queue.
    ///
    /// - Parameter frame: The remote video frame after interpolation and other processing.
    func dispatch(
        _ frame: RealtimeVideoFrame
    ) {
        let version = stateLock.withLock { () -> Int? in
            guard state.listener != nil else { return nil }
            return state.version
        }
        guard let version else { return }

        deliveryQueue.async { [weak self] in
            guard let listener = self?.listener(for: version) else {
                return
            }
            listener(frame)
        }
    }

    /// Reads the current listener matching the delivery version.
    ///
    /// - Parameter version: The listener version recorded when enqueueing.
    ///
    /// - Returns: The valid listener, or `nil` if the version expired or the listener was cleared.
    private func listener(
        for version: Int
    ) -> RealtimeVideoFrameListener? {
        stateLock.withLock {
            guard state.version == version else { return nil }
            return state.listener
        }
    }
}

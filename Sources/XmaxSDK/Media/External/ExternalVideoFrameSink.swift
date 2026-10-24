//
//  ExternalVideoFrameSink.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreVideo
import Foundation

/// Serializes external frame submission and invalidates a binding before source cleanup.
final class ExternalVideoFrameSink: RealtimeExternalFrameSink, @unchecked Sendable {

    /// The resolved media format used for preview and quality baselines.
    let videoFormat: RealtimeVideoFormat

    /// The demand check for the current generation task.
    private let requestingFrames: @Sendable () -> Bool

    /// The synchronous receiver of copied external video frames.
    private let videoFrameListener: MediaVideoFrameListener

    /// The unrecoverable failure handler for this binding.
    private let errorListener: XmaxErrorListener

    /// The lock serializing binding state, timestamps, and frame submission.
    private let lock = NSLock()

    /// Whether the binding accepts frames; failure or unbinding permanently invalidates it.
    private var active = true

    /// The last accepted timestamp, in microseconds.
    private var lastTimestampUs: Int64 = -1

    /// Creates the sink for one binding with immutable negotiated input configuration.
    init(
        videoFormat: RealtimeVideoFormat,
        requestingFrames: @escaping @Sendable () -> Bool,
        videoFrameListener: @escaping MediaVideoFrameListener,
        errorListener: @escaping XmaxErrorListener
    ) {
        self.videoFormat = videoFormat
        self.requestingFrames = requestingFrames
        self.videoFrameListener = videoFrameListener
        self.errorListener = errorListener
    }

    /// Whether this binding is active and generation currently requests input.
    var isRequestingFrames: Bool {
        lock.withLock { active && requestingFrames() }
    }

    /// Copies and submits a valid requested frame synchronously under the binding lock.
    func pushVideo(
        _ pixelBuffer: CVPixelBuffer,
        timestampUs: Int64
    ) {
        lock.withLock {
            guard active, requestingFrames(), timestampUs >= 0, timestampUs > lastTimestampUs else { return }
            do {
                let frame = try ExternalVideoFrameConverter.convert(
                    pixelBuffer,
                    videoFormat: videoFormat,
                    timestampUs: timestampUs
                )
                lastTimestampUs = timestampUs
                try videoFrameListener(frame)
            } catch {
                reportFailure(error)
            }
        }
    }

    /// Reports errors only while this binding remains active.
    func reportError(
        _ error: any Error
    ) {
        lock.withLock {
            guard active else { return }
            reportFailure(error)
        }
    }

    /// Waits for in-flight submission and permanently rejects subsequent input.
    func invalidate() {
        lock.withLock { active = false }
    }

    /// Forwards the first binding failure; the SDK lifecycle handler performs cleanup.
    private func reportFailure(
        _ error: any Error
    ) {
        active = false
        errorListener(
            XmaxError(
                code: .mediaError,
                message: "External video source failed: \(error.localizedDescription)"
            )
        )
    }
}

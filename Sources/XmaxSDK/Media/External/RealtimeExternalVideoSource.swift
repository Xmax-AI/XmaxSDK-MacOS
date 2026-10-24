//
//  RealtimeExternalVideoSource.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import CoreVideo

/// A caller-owned video source for camera, decoder, or processed video input.
///
/// The caller owns permissions, capture, device switching, and final resource release.
/// The SDK only binds and unbinds frame delivery. Lifecycle and preview methods run
/// on the main actor; frames may be submitted synchronously from a capture queue.
@MainActor
public protocol RealtimeExternalVideoSource: AnyObject, Sendable {

    /// The source display format before conversion to the sink's requested format.
    var videoFormat: RealtimeVideoFormat { get }

    /// Binds frame delivery and returns once the sink is stored and usable.
    ///
    /// Produce upright, correctly mirrored frames matching `sink.videoFormat`.
    /// Do not await generation completion here or wait for `startGeneration` to return
    /// before supplying frames. A failed or cancelled start is followed by `stop()`.
    ///
    /// - Parameter sink: The SDK frame receiver for this binding.
    ///
    /// - Throws: An error if the source cannot bind frame delivery.
    func start(
        sink: any RealtimeExternalFrameSink
    ) async throws

    /// Unbinds frame delivery and clears the stored sink; repeated calls must be safe.
    /// This does not transfer ownership of the caller's camera or decoder to the SDK.
    func stop() async

    /// Optionally mounts a caller-owned preview in the SDK container.
    ///
    /// - Parameters:
    ///   - container: The AppKit container hosting the preview.
    ///   - contentMode: The requested proportional fitting or cropping mode.
    func attachPreview(
        to container: NSView,
        contentMode: VideoContentMode
    )

    /// Removes a preview from its container without stopping capture.
    ///
    /// - Parameter container: The container previously hosting the preview.
    func detachPreview(
        from container: NSView
    )
}

public extension RealtimeExternalVideoSource {

    /// Leaves preview presentation to the caller by default.
    func attachPreview(
        to container: NSView,
        contentMode: VideoContentMode
    ) {}

    /// Performs no preview cleanup when no SDK preview was mounted.
    func detachPreview(
        from container: NSView
    ) {}
}

/// A synchronous video input bound to one external source lifecycle.
///
/// This input accepts video only. The SDK copies pixels during `pushVideo`;
/// the caller may reuse the input buffer after the method returns, but must not
/// modify it concurrently with submission. Stale bindings silently discard input.
public protocol RealtimeExternalFrameSink: AnyObject, Sendable {

    /// The final input dimensions, frame rate, and encoding options required by the SDK.
    var videoFormat: RealtimeVideoFormat { get }

    /// Whether generation currently requests frames from this binding.
    /// When false, skip conversion and submission while keeping caller-owned preview running.
    /// This is a demand signal, not a frame-rate limiter.
    var isRequestingFrames: Bool { get }

    /// Submits one upright NV12 video-range or BGRA pixel buffer of the exact requested size.
    ///
    /// Frames must be paced by the caller and submitted in timestamp order. Duplicate,
    /// decreasing, or negative timestamps are ignored. No rotation, mirroring, cropping,
    /// or scaling is performed. Invalid pixels are reported as media failures.
    ///
    /// - Parameters:
    ///   - pixelBuffer: A `420v` NV12 or `32BGRA` pixel buffer.
    ///   - timestampUs: A nonnegative, strictly increasing monotonic timestamp in microseconds.
    func pushVideo(
        _ pixelBuffer: CVPixelBuffer,
        timestampUs: Int64
    )

    /// Reports an unrecoverable capture or conversion failure for the current binding.
    ///
    /// - Parameter error: The failure ending external media input.
    func reportError(
        _ error: any Error
    )
}

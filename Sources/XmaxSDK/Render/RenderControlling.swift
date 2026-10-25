//
//  RenderControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Asynchronously receives interaction frames captured by the render view.
typealias RenderInteractionListener =
    @Sendable (
        _ frame: InteractionFrame
    ) async -> Void

/// Defines unified render capabilities exposed to Core.
@MainActor
protocol RenderControlling: AnyObject, Sendable {

    /// Whether remote video interpolation is currently enabled.
    var isFrameInterpolationEnabled: Bool { get async }

    /// Enables interaction only after generation confirmation; false cancels active gestures.
    func setInteractionEnabled(
        _ enabled: Bool
    )

    /// Updates the decoded frame source and invalidates old stream caches and waits.
    ///
    /// - Parameter stream: The new remote stream; `nil` clears the source.
    ///
    /// - Throws: An error if removing the old listener or binding the new listener fails.
    func setRemoteStream(
        _ stream: RemoteStream?
    ) throws

    /// Registers a video render binding for the remote track.
    ///
    /// - Parameters:
    ///   - track: The remote video track to register.
    ///   - resolvedMediaSize: The resolved local media dimensions retained for trajectory mapping.
    ///   - interactionListener: The asynchronous callback receiving view interaction samples.
    func registerRemoteTrack(
        _ track: RealtimeVideoTrack,
        resolvedMediaSize: CGSize,
        interactionListener: @escaping RenderInteractionListener
    )

    /// Updates the remote track display format.
    ///
    /// - Parameters:
    ///   - videoFormat: The new video mapping format.
    ///   - track: The remote video track to update.
    func updateRemoteVideoFormat(
        _ videoFormat: RealtimeVideoFormat,
        for track: RealtimeVideoTrack
    )

    /// Enables or disables remote video interpolation.
    ///
    /// - Parameters:
    ///   - enabled: Whether to enable interpolation.
    ///   - videoFormat: The expected return video format; nil before local stream creation.
    ///
    /// - Throws: Explicit enablement throws if the device or video format does not support interpolation.
    func setFrameInterpolationEnabled(
        _ enabled: Bool,
        videoFormat: RealtimeVideoFormat?
    ) async throws

    /// Waits for the first processed frame from the current remote stream that can be displayed immediately.
    ///
    /// - Throws: An error on cancellation, remote stream reset, or first-frame timeout.
    func waitUntilRemoteFrameReady() async throws

    /// Unregisters remote track bindings, resets display, and waits for in-flight frame processing.
    ///
    /// - Parameter track: The remote track to unregister; frame processing is cleared even without a track.
    ///
    /// - Throws: An error if removing the RTC frame listener fails.
    func resetRemoteTrack(
        _ track: RealtimeVideoTrack?
    ) async throws
    /// Sets unified PCM and processed video output on a bounded serial background queue.
    ///
    /// - Parameter listener: The media callback; nil removes it and queued packets.
    ///
    /// - Throws: An error if native remote audio observation cannot be configured.
    @MainActor
    func setRemoteMediaFrameListener(
        _ listener: RealtimeMediaFrameListener?
    ) throws

}

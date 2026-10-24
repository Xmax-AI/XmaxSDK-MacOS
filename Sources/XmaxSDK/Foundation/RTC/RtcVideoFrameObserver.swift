//
//  RtcVideoFrameObserver.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit
import Foundation

/// Observes remote result pixels only. Native local preview is rendered directly by Agora.
final class RtcVideoFrameObserver: NSObject, AgoraVideoFrameDelegate, @unchecked Sendable {

    /// The lock protecting the current remote frame sink.
    private let stateLock = NSLock()

    /// The remote frame receiver protected by the state lock.
    private var remote: RtcRemoteVideoSink?

    /// Replaces the remote frame receiver without invoking it under the state lock.
    func setRemote(
        _ sink: RtcRemoteVideoSink?
    ) { stateLock.withLock { remote = sink } }

    /// Requests native NV12 pixel buffers.
    func getVideoFormatPreference() -> AgoraVideoFormat { .cvPixelNV12 }

    /// Requests frames immediately before remote rendering.
    func getObservedFramePosition() -> AgoraVideoFramePosition { .preRenderer }

    /// Observes pixels without modifying the native frame.
    func getVideoFrameProcessMode() -> AgoraVideoFrameProcessMode { .readOnly }

    /// Requests frames with rotation already applied.
    func getRotationApplied() -> Bool { true }

    /// Keeps native mirroring out of the returned pixels.
    func getMirrorApplied() -> Bool { false }

    /// Forwards a remote frame after releasing the sink state lock.
    func onRenderVideoFrame(
        _ frame: AgoraOutputVideoFrame,
        uid: UInt,
        channelId: String
    ) -> Bool {
        stateLock.withLock { remote }?.onRenderVideoFrame(
            frame,
            uid: uid,
            channelId: channelId
        ) ?? true
    }
}

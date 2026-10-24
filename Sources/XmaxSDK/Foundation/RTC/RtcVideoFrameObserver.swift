@preconcurrency import AgoraRtcKit
import Foundation

/// Observes remote result pixels only. Native local preview is rendered directly by Agora.
final class RtcVideoFrameObserver: NSObject, AgoraVideoFrameDelegate, @unchecked Sendable {
    private let stateLock = NSLock()
    private var remote: RtcRemoteVideoSink?

    func setRemote(_ sink: RtcRemoteVideoSink?) { stateLock.withLock { remote = sink } }
    func getVideoFormatPreference() -> AgoraVideoFormat { .cvPixelNV12 }
    func getObservedFramePosition() -> AgoraVideoFramePosition { .preRenderer }
    func getVideoFrameProcessMode() -> AgoraVideoFrameProcessMode { .readOnly }
    func getRotationApplied() -> Bool { true }
    func getMirrorApplied() -> Bool { false }

    func onRenderVideoFrame(_ frame: AgoraOutputVideoFrame, uid: UInt, channelId: String) -> Bool {
        stateLock.withLock { remote }?.onRenderVideoFrame(frame, uid: uid, channelId: channelId) ?? true
    }
}

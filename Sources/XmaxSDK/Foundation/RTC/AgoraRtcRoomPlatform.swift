@preconcurrency import AgoraRtcKit
import Foundation

/// The room's engine operations are serialized separately from its callback state.
protocol AgoraRtcRoomPlatform: AnyObject, Sendable {
    var roomEngine: any AgoraRtcRoomEngine { get }
    var lock: NSRecursiveLock { get }
    var audioTrackID: Int? { get }
    var usesCameraTrack: Bool { get }
    func setRemoteVideoSink(_ sink: RtcRemoteVideoSink?) -> Bool
    func reapplyVideoConfiguration() throws
}

extension AgoraRtcRoomPlatform {
    var usesCameraTrack: Bool { false }
    func setRemoteVideoSink(_ sink: RtcRemoteVideoSink?) -> Bool { roomEngine.setVideoFrameDelegate(sink) }
}

/// Allows the real room lifecycle to be exercised without starting a vendor engine.
protocol AgoraRtcRoomEngine: AnyObject {
    func setVideoFrameDelegate(_ delegate: (any AgoraVideoFrameDelegate)?) -> Bool
    func joinChannelEx(
        byToken token: String?, channelId: String, userAccount: String,
        delegate: (any AgoraRtcEngineDelegate)?, mediaOptions: AgoraRtcChannelMediaOptions,
        joinSuccess: ((String, UInt, Int) -> Void)?
    ) -> Int32
    func leaveChannelEx(
        _ channelId: String, userAccount: String, leaveChannelBlock: ((AgoraChannelStats) -> Void)?
    ) -> Int32
    func updateChannelEx(with options: AgoraRtcChannelMediaOptions, connection: AgoraRtcConnection) -> Int32
    func muteRemoteVideoStreamEx(_ uid: UInt, mute: Bool, connection: AgoraRtcConnection) -> Int32
    func muteRemoteAudioStreamEx(_ uid: UInt, mute: Bool, connection: AgoraRtcConnection) -> Int32
    func adjustUserPlaybackSignalVolumeEx(_ uid: UInt, volume: Int, connection: AgoraRtcConnection) -> Int32
    func createDataStreamEx(
        _ streamId: UnsafeMutablePointer<Int>, config: AgoraDataStreamConfig, connection: AgoraRtcConnection
    ) -> Int32
    func sendStreamMessageEx(_ streamId: Int, data: Data, connection: AgoraRtcConnection) -> Int32
    func getUserInfo(byUidEx uid: UInt, connection: AgoraRtcConnection, withError error: UnsafeMutablePointer<AgoraErrorCode>?) -> AgoraUserInfo?
    func getUserInfo(byUserAccountEx account: String, connection: AgoraRtcConnection, withError error: UnsafeMutablePointer<AgoraErrorCode>?) -> AgoraUserInfo?
}

extension AgoraRtcEngineKit: AgoraRtcRoomEngine {}

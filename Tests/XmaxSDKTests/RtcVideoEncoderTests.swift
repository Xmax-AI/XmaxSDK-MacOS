@preconcurrency import AgoraRtcKit
import XCTest
@testable import XmaxSDK

/// Verifies encoder configuration through the RTC manager and Agora platform.
final class RtcVideoEncoderTests: XCTestCase, @unchecked Sendable {
    func testProcessedVideoKeepsPortraitDimensionsWithoutEncoderMirroring() async throws {
        let engine = RecordingAgoraVideoEncoder()
        let manager = makeManager(engine)
        try await manager.initialize()
        try manager.configureVideoEncoding(VideoEncodingConfiguration(width: 720, height: 1280, frameRate: 30))
        try manager.useExternalVideoSource()
        try await manager.joinRoom(configuration: RoomJoinConfiguration(roomID: "room", userID: "user", token: "token"))
        try manager.publishLocalVideo()
        XCTAssertTrue(engine.encodedMirrors.allSatisfy { $0 == .disabled })
        XCTAssertTrue(engine.encodedDimensions.allSatisfy { $0 == CGSize(width: 720, height: 1280) })
        XCTAssertTrue(engine.encodedOrientations.allSatisfy { $0 == .adaptative })
        await manager.destroy()
    }

    private func makeManager(_ encoder: RecordingAgoraVideoEncoder) -> RtcManager {
        let platform = AgoraRtcPlatform(
            engine: encoder.vendor,
            roomEngine: encoder,
            videoEncoder: encoder
        )
        return RtcManager(engineManager: RtcEngineManager(
            appID: "test", makeEngine: { _ in platform }, destroyEngine: {}
        ))
    }
}

private final class RecordingAgoraVideoEncoder: AgoraRtcVideoEncoder, AgoraRtcRoomEngine, @unchecked Sendable {
    let vendor = AgoraRtcEngineKit()
    private let stateLock = NSLock()
    private let failingEncoderCalls: Set<Int>
    private var storedEncodedMirrors: [AgoraVideoMirrorMode] = []
    private var storedEncodedDimensions: [CGSize] = []
    private var storedEncodedOrientations: [AgoraVideoOutputOrientationMode] = []

    var encodedMirrors: [AgoraVideoMirrorMode] { stateLock.withLock { storedEncodedMirrors } }
    var encodedDimensions: [CGSize] { stateLock.withLock { storedEncodedDimensions } }
    var encodedOrientations: [AgoraVideoOutputOrientationMode] { stateLock.withLock { storedEncodedOrientations } }

    init(failingEncoderCalls: Set<Int> = []) {
        self.failingEncoderCalls = failingEncoderCalls
    }

    func setVideoEncoderConfiguration(_ config: AgoraVideoEncoderConfiguration) -> Int32 {
        stateLock.withLock {
            storedEncodedMirrors.append(config.mirrorMode)
            storedEncodedDimensions.append(config.dimensions)
            storedEncodedOrientations.append(config.orientationMode)
            return failingEncoderCalls.contains(storedEncodedMirrors.count) ? -1 : 0
        }
    }

    func setVideoEncoderConfigurationEx(_ config: AgoraVideoEncoderConfiguration, connection: AgoraRtcConnection) -> Int32 {
        setVideoEncoderConfiguration(config)
    }

    func setAudioFrameDelegate(_ delegate: (any AgoraAudioFrameDelegate)?) -> Bool { true }

    func setPlaybackAudioFrameBeforeMixingParametersWithSampleRate(
        _ sampleRate: Int, channel: Int, samplesPerCall: Int
    ) -> Int32 { 0 }

    func setVideoFrameDelegate(_ delegate: (any AgoraVideoFrameDelegate)?) -> Bool { true }

    func joinChannelEx(
        byToken token: String?, channelId: String, userAccount: String,
        delegate: (any AgoraRtcEngineDelegate)?, mediaOptions: AgoraRtcChannelMediaOptions,
        joinSuccess: ((String, UInt, Int) -> Void)?
    ) -> Int32 {
        delegate?.rtcEngine?(vendor, didJoinChannel: channelId, withUid: 1, elapsed: 0)
        return 0
    }

    func createDataStreamEx(
        _ streamId: UnsafeMutablePointer<Int>, config: AgoraDataStreamConfig, connection: AgoraRtcConnection
    ) -> Int32 {
        streamId.pointee = 1
        return 0
    }

    func leaveChannelEx(
        _ channelId: String, userAccount: String, leaveChannelBlock: ((AgoraChannelStats) -> Void)?
    ) -> Int32 { 0 }

    func updateChannelEx(with options: AgoraRtcChannelMediaOptions, connection: AgoraRtcConnection) -> Int32 { 0 }
    func muteRemoteVideoStreamEx(_ uid: UInt, mute: Bool, connection: AgoraRtcConnection) -> Int32 { 0 }
    func muteRemoteAudioStreamEx(_ uid: UInt, mute: Bool, connection: AgoraRtcConnection) -> Int32 { 0 }
    func adjustUserPlaybackSignalVolumeEx(_ uid: UInt, volume: Int, connection: AgoraRtcConnection) -> Int32 { 0 }
    func sendStreamMessageEx(_ streamId: Int, data: Data, connection: AgoraRtcConnection) -> Int32 { 0 }
    func getUserInfo(byUidEx uid: UInt, connection: AgoraRtcConnection, withError error: UnsafeMutablePointer<AgoraErrorCode>?) -> AgoraUserInfo? { nil }
    func getUserInfo(byUserAccountEx account: String, connection: AgoraRtcConnection, withError error: UnsafeMutablePointer<AgoraErrorCode>?) -> AgoraUserInfo? { nil }
}

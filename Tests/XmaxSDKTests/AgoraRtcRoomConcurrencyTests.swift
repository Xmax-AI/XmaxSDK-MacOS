import CoreVideo
import Foundation
@preconcurrency import AgoraRtcKit
import XCTest
@testable import XmaxSDK

final class AgoraRtcRoomConcurrencyTests: XCTestCase, @unchecked Sendable {
    func testJoinDoesNotRegisterObserverUntilRemoteFramesAreRequested() async throws {
        let (room, engine) = try await joinedRoom()
        defer { room.destroy() }
        XCTAssertEqual(engine.registrationCount, 0, "Entering the RTC room must not wait for raw video registration")
        XCTAssertNil(engine.videoDelegate)

        try room.setRemoteVideoFrameListener({ _ in }, for: "bot")
        XCTAssertEqual(engine.registrationCount, 1)
        XCTAssertNotNil(engine.videoDelegate)
        try room.setRemoteVideoFrameListener(nil, for: "bot")
        XCTAssertEqual(engine.registrationCount, 1, "Removing a listener must not register an observer")
    }

    func testUnpublishLetsInFlightVideoCallbackReturn() async throws {
        let (room, engine) = try await joinedRoom()
        defer { room.destroy() }
        let frame = try makeFrame()
        let delivered = expectation(description: "Decoded frame delivered")
        try room.setRemoteVideoFrameListener({ _ in delivered.fulfill() }, for: "bot")
        let sink = try XCTUnwrap(engine.videoDelegate)
        engine.onUpdate = {
            engine.waitForCallback {
                _ = sink.onRenderVideoFrame?(frame, uid: 42, channelId: "room")
            }
        }

        try room.publishLocalVideo(false)

        XCTAssertEqual(engine.callbackReturned, true,
                       "Stopping publication must not wait on a frame callback waiting for its lock")
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testUnpublishLetsRoomEventCallbackReturnBeforeProcessingIt() async throws {
        let (room, engine) = try await joinedRoom()
        defer { room.destroy() }
        let delivered = expectation(description: "Publication event delivered")
        room.setEventListener {
            if case .publication(userID: "bot", published: false) = $0 { delivered.fulfill() }
        }
        let delegate = try XCTUnwrap(engine.roomDelegate)
        engine.onUpdate = {
            engine.waitForCallback {
                delegate.rtcEngine?(engine.vendor, didVideoMuted: true, byUid: 42)
            }
        }

        try room.publishLocalVideo(false)

        XCTAssertEqual(engine.callbackReturned, true,
                       "Agora event callbacks must return while the control operation is still running")
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testDestroyInvalidatesFramesBeforeUnregisteringObserver() async throws {
        let (room, engine) = try await joinedRoom()
        let frame = try makeFrame()
        let unexpectedFrame = expectation(description: "Closed room must not deliver frames")
        unexpectedFrame.isInverted = true
        try room.setRemoteVideoFrameListener({ _ in unexpectedFrame.fulfill() }, for: "bot")
        let sink = try XCTUnwrap(engine.videoDelegate)
        engine.onUnregister = {
            engine.waitForCallback {
                _ = sink.onRenderVideoFrame?(frame, uid: 42, channelId: "room")
            }
        }

        room.destroy()
        room.destroy()

        XCTAssertEqual(engine.callbackReturned, true,
                       "Unregistering the observer must not deadlock an in-flight video callback")
        XCTAssertEqual(engine.leaveCount, 1)
        await fulfillment(of: [unexpectedFrame], timeout: 0.1)
    }

    func testQueuedStatisticsOwnValuesBeforeVendorCallbackReturns() async throws {
        let (room, engine) = try await joinedRoom()
        defer { room.destroy() }
        let delivered = expectation(description: "Statistics delivered")
        delivered.expectedFulfillmentCount = 2
        room.setEventListener { event in
            switch event {
            case .uplinkVideoStatistics(let statistics):
                XCTAssertEqual(statistics.sendFrameRate, 24)
                delivered.fulfill()
            case .downlinkVideoStatistics(let statistics):
                XCTAssertEqual(statistics.userID, "bot")
                XCTAssertEqual(statistics.decodeFrameRate, 24)
                delivered.fulfill()
            default: break
            }
        }
        let delegate = try XCTUnwrap(engine.roomDelegate)
        engine.onUpdate = {
            engine.waitForCallback {
                let local = AgoraRtcLocalVideoStats()
                local.sentFrameRate = 24
                delegate.rtcEngine?(engine.vendor, localVideoStats: local, sourceType: .camera)
                local.sentFrameRate = 99
                let remote = AgoraRtcRemoteVideoStats()
                remote.uid = 42
                remote.decoderOutputFrameRate = 24
                delegate.rtcEngine?(engine.vendor, remoteVideoStats: remote)
                remote.decoderOutputFrameRate = 99
            }
        }

        try room.publishLocalVideo(false)

        XCTAssertEqual(engine.callbackReturned, true)
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testLateRoomEventsAreIgnoredAfterDestroy() async throws {
        let (room, engine) = try await joinedRoom()
        let delegate = try XCTUnwrap(engine.roomDelegate)
        let unexpected = expectation(description: "Destroyed room must not deliver queued events")
        unexpected.isInverted = true
        room.setEventListener { _ in unexpected.fulfill() }
        room.destroy()

        delegate.rtcEngine?(engine.vendor, didVideoMuted: true, byUid: 42)

        await fulfillment(of: [unexpected], timeout: 0.1)
    }

    func testNativeCameraPublishesCameraTrackWithoutCustomVideo() async throws {
        let (room, engine) = try await joinedRoom(usesCameraTrack: true)
        defer { room.destroy() }
        try room.publishLocalVideo(true)
        XCTAssertEqual(engine.lastVideoPublication?.camera, true)
        XCTAssertEqual(engine.lastVideoPublication?.custom, false)
        try room.publishLocalVideo(false)
        XCTAssertEqual(engine.lastVideoPublication?.camera, false)
        XCTAssertEqual(engine.lastVideoPublication?.custom, false)
    }

    func testExternalSourceStillPublishesCustomVideoWithoutCameraTrack() async throws {
        let (room, engine) = try await joinedRoom()
        defer { room.destroy() }
        try room.publishLocalVideo(true)
        XCTAssertEqual(engine.lastVideoPublication?.camera, false)
        XCTAssertEqual(engine.lastVideoPublication?.custom, true)
    }

    func testUnpublishLetsInFlightAudioCallbackReturn() async throws {
        let (room, engine) = try await joinedRoom()
        defer { room.destroy() }
        let delivered = expectation(description: "Owned PCM delivered")
        try room.setRemoteAudioFrameListener({ frame in
            XCTAssertEqual(frame.data.count, 960)
            delivered.fulfill()
        }, for: "bot")
        let sink = try XCTUnwrap(engine.audioDelegate as? RtcRemoteAudioSink)
        engine.onUpdate = {
            engine.waitForCallback {
                Data(repeating: 0x35, count: 960).withUnsafeBytes { bytes in
                    sink.capturePCM(bytes.baseAddress, channelID: "room", uid: 42,
                                    samplesPerChannel: 480, sampleRate: 48000, channels: 1,
                                    bytesPerSample: 2, renderTimeMs: 1000)
                }
            }
        }
        try room.publishLocalVideo(false)
        XCTAssertEqual(engine.callbackReturned, true)
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testDestroyRejectsLateAudioBeforeUnregisteringItsObserver() async throws {
        let (room, engine) = try await joinedRoom()
        let unexpected = expectation(description: "Closed room must reject native PCM")
        unexpected.isInverted = true
        try room.setRemoteAudioFrameListener({ _ in unexpected.fulfill() }, for: "bot")
        let sink = try XCTUnwrap(engine.audioDelegate as? RtcRemoteAudioSink)
        engine.onAudioUnregister = {
            engine.waitForCallback {
                Data(repeating: 0x35, count: 960).withUnsafeBytes { bytes in
                    sink.capturePCM(bytes.baseAddress, channelID: "room", uid: 42,
                                    samplesPerChannel: 480, sampleRate: 48000, channels: 1,
                                    bytesPerSample: 2, renderTimeMs: 1000)
                }
            }
        }
        room.destroy()
        XCTAssertEqual(engine.callbackReturned, true)
        XCTAssertNil(engine.audioDelegate)
        await fulfillment(of: [unexpected], timeout: 0.1)
    }

    private func joinedRoom(usesCameraTrack: Bool = false) async throws -> (AgoraRtcRoom, CallbackWaitingAgoraEngine) {
        let engine = CallbackWaitingAgoraEngine()
        let platform = CallbackWaitingRoomPlatform(engine: engine, usesCameraTrack: usesCameraTrack)
        let room = AgoraRtcRoom(platform: platform, roomID: "room")
        let joined = expectation(description: "Room joined")
        room.setEventListener { if case .joined = $0 { joined.fulfill() } }
        try room.join(configuration: RoomJoinConfiguration(roomID: "room", userID: "host", token: "test"))
        await fulfillment(of: [joined], timeout: 2)
        return (room, engine)
    }

    private func makeFrame() throws -> AgoraOutputVideoFrame {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let frame = AgoraOutputVideoFrame()
        frame.pixelBuffer = try XCTUnwrap(buffer)
        return frame
    }
}

/// Simulates an SDK control call waiting for a callback on another thread; no vendor engine is started.
private final class CallbackWaitingAgoraEngine: AgoraRtcRoomEngine, @unchecked Sendable {
    let vendor = AgoraRtcEngineKit()
    var videoDelegate: (any AgoraVideoFrameDelegate)?
    var roomDelegate: (any AgoraRtcEngineDelegate)?
    var onUpdate: (() -> Void)?
    var onUnregister: (() -> Void)?
    var onAudioUnregister: (() -> Void)?
    var callbackReturned: Bool?
    var leaveCount = 0
    var registrationCount = 0
    var lastVideoPublication: (camera: Bool, custom: Bool)?

    func waitForCallback(_ callback: @escaping @Sendable () -> Void) {
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { callback(); returned.signal() }
        // Bound the simulated SDK wait so a regression fails without hanging the test process.
        callbackReturned = returned.wait(timeout: .now() + .seconds(1)) == .success
    }

    var audioDelegate: (any AgoraAudioFrameDelegate)?
    func setAudioFrameDelegate(_ delegate: (any AgoraAudioFrameDelegate)?) -> Bool {
        if delegate == nil { onAudioUnregister?() }
        audioDelegate = delegate
        return true
    }
    func setPlaybackAudioFrameBeforeMixingParametersWithSampleRate(
        _ sampleRate: Int, channel: Int, samplesPerCall: Int
    ) -> Int32 { 0 }

    func setVideoFrameDelegate(_ delegate: (any AgoraVideoFrameDelegate)?) -> Bool {
        if delegate != nil { registrationCount += 1 }
        if delegate == nil { onUnregister?() }
        videoDelegate = delegate
        return true
    }

    func joinChannelEx(
        byToken token: String?, channelId: String, userAccount: String,
        delegate: (any AgoraRtcEngineDelegate)?, mediaOptions: AgoraRtcChannelMediaOptions,
        joinSuccess: ((String, UInt, Int) -> Void)?
    ) -> Int32 {
        roomDelegate = delegate
        let user = AgoraUserInfo()
        user.uid = 42
        user.userAccount = "bot"
        delegate?.rtcEngine?(vendor, didUserInfoUpdatedWithUserId: 42, userInfo: user)
        delegate?.rtcEngine?(vendor, didJoinChannel: channelId, withUid: 1, elapsed: 0)
        return 0
    }

    func createDataStreamEx(
        _ streamId: UnsafeMutablePointer<Int>, config: AgoraDataStreamConfig, connection: AgoraRtcConnection
    ) -> Int32 {
        streamId.pointee = 1
        return 0
    }

    func updateChannelEx(with options: AgoraRtcChannelMediaOptions, connection: AgoraRtcConnection) -> Int32 {
        lastVideoPublication = (options.publishCameraTrack, options.publishCustomVideoTrack)
        onUpdate?()
        return 0
    }

    func leaveChannelEx(
        _ channelId: String, userAccount: String, leaveChannelBlock: ((AgoraChannelStats) -> Void)?
    ) -> Int32 {
        leaveCount += 1
        return 0
    }
}

private final class CallbackWaitingRoomPlatform: AgoraRtcRoomPlatform, @unchecked Sendable {
    let roomEngine: any AgoraRtcRoomEngine
    let lock = NSRecursiveLock()
    let audioTrackID: Int? = nil
    let usesCameraTrack: Bool
    init(engine: any AgoraRtcRoomEngine, usesCameraTrack: Bool = false) {
        roomEngine = engine
        self.usesCameraTrack = usesCameraTrack
    }
    func reapplyVideoConfiguration() throws {}
}

private extension CallbackWaitingAgoraEngine {
    func muteRemoteVideoStreamEx(_ uid: UInt, mute: Bool, connection: AgoraRtcConnection) -> Int32 { 0 }
    func muteRemoteAudioStreamEx(_ uid: UInt, mute: Bool, connection: AgoraRtcConnection) -> Int32 { 0 }
    func adjustUserPlaybackSignalVolumeEx(_ uid: UInt, volume: Int, connection: AgoraRtcConnection) -> Int32 { 0 }
    func sendStreamMessageEx(_ streamId: Int, data: Data, connection: AgoraRtcConnection) -> Int32 { 0 }
    func getUserInfo(byUidEx uid: UInt, connection: AgoraRtcConnection, withError error: UnsafeMutablePointer<AgoraErrorCode>?) -> AgoraUserInfo? { nil }
    func getUserInfo(byUserAccountEx account: String, connection: AgoraRtcConnection, withError error: UnsafeMutablePointer<AgoraErrorCode>?) -> AgoraUserInfo? { nil }
}

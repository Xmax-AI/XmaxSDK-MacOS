import AppKit
@preconcurrency import AgoraRtcKit
import XCTest
@testable import XmaxSDK

/// Exercises both real SDK adapter layers, blocking only the vendor camera call.
final class RtcCameraJoinConcurrencyTests: XCTestCase, @unchecked Sendable {
    func testAgoraEncoderRetainsExplicitMirrorAcrossQualityUpdatesAndReconnection() async throws {
        let engine = BlockingCameraAgoraEngine(onCameraStart: {})
        let manager = makeManager(engine)
        try await manager.initialize()
        try manager.configureLocalVideoMirror(true)
        try manager.configureVideoEncoding(VideoEncodingConfiguration(width: 4, height: 4, frameRate: 30))
        XCTAssertEqual(engine.encodedMirrors, [.enabled])
        try manager.configureVideoEncoding(VideoEncodingConfiguration(width: 8, height: 4, frameRate: 24))
        XCTAssertEqual(engine.encodedMirrors.last, .enabled)
        let configuration = RoomJoinConfiguration(roomID: "room", userID: "host", token: "test")
        try await manager.joinRoom(configuration: configuration)
        XCTAssertEqual(engine.encodedMirrors.last, .enabled)
        await manager.leaveRoom()
        try await manager.joinRoom(configuration: configuration)
        XCTAssertEqual(engine.encodedMirrors.last, .enabled)
        try manager.configureLocalVideoMirror(false)
        XCTAssertEqual(engine.encodedMirrors.last, .disabled)
        try manager.configureLocalVideoMirror(true)
        try manager.useExternalVideoSource()
        XCTAssertEqual(engine.encodedMirrors.last, .disabled, "External input must not inherit the camera mirror")
        try manager.configureVideoEncoding(VideoEncodingConfiguration(width: 12, height: 8, frameRate: 30))
        XCTAssertEqual(engine.encodedMirrors.last, .disabled)
        await manager.destroy()
    }

    func testFailedAgoraMirrorUpdateRestoresPreviousSettingForSubsequentEncoding() async throws {
        let engine = BlockingCameraAgoraEngine(onCameraStart: {}, failingEncoderCalls: [2])
        let manager = makeManager(engine)
        try await manager.initialize()
        try manager.configureVideoEncoding(VideoEncodingConfiguration(width: 4, height: 4, frameRate: 30))
        XCTAssertThrowsError(try manager.configureLocalVideoMirror(true))
        try manager.configureVideoEncoding(VideoEncodingConfiguration(width: 8, height: 4, frameRate: 30))
        XCTAssertEqual(engine.encodedMirrors, [.disabled, .enabled, .disabled])
        await manager.destroy()
    }

    func testNativeCameraCanStartWhileVendorJoinCallIsBlocked() async throws {
        let entered = expectation(description: "Vendor join call entered")
        let captured = expectation(description: "Camera starts before vendor join returns")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = BlockingCameraAgoraEngine(onCameraStart: {}, onJoin: {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        })
        let manager = makeManager(engine)
        try await manager.initialize()
        let join = Task.detached {
            try await manager.joinRoom(configuration: RoomJoinConfiguration(roomID: "room", userID: "host", token: "test"))
        }
        await fulfillment(of: [entered], timeout: 2)
        let camera = Task.detached {
            try self.startCamera(manager)
            captured.fulfill()
        }
        await fulfillment(of: [captured], timeout: 1)
        gate.signal()
        try await camera.value
        try await join.value
        await manager.destroy()
    }

    func testRoomCanJoinAndDeliverCallbackWhileNativeCameraStartupIsBlocked() async throws {
        let entered = expectation(description: "Native camera call entered")
        let joined = expectation(description: "RTC joins before the camera call returns")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = BlockingCameraAgoraEngine(onCameraStart: {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        })
        let manager = makeManager(engine)
        try await manager.initialize()
        let camera = Task.detached { try self.startCamera(manager) }
        await fulfillment(of: [entered], timeout: 2)
        let join = Task.detached {
            try await manager.joinRoom(configuration: RoomJoinConfiguration(roomID: "room", userID: "host", token: "test"))
            joined.fulfill()
        }
        await fulfillment(of: [joined], timeout: 1)
        XCTAssertFalse(engine.cameraReturned)
        gate.signal()
        try await camera.value
        try await join.value
        await manager.destroy()
    }

    func testEngineDestructionWaitsForInFlightCameraCall() async throws {
        let entered = expectation(description: "Native camera call entered")
        let leftRoom = expectation(description: "Room resources released independently of camera startup")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = BlockingCameraAgoraEngine(onCameraStart: {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        }, onLeave: { leftRoom.fulfill() })
        let destroyed = CameraEngineDestruction()
        let manager = makeManager(engine, destroy: { destroyed.record() })
        try await manager.initialize()
        let join = Task.detached {
            try await manager.joinRoom(configuration: RoomJoinConfiguration(roomID: "room", userID: "host", token: "test"))
        }
        try await join.value
        let camera = Task.detached { try self.startCamera(manager) }
        await fulfillment(of: [entered], timeout: 2)
        let close = Task.detached { await manager.destroy() }
        await fulfillment(of: [leftRoom], timeout: 1)
        XCTAssertEqual(destroyed.count, 0, "Releasing the room must not destroy an engine still capturing")
        gate.signal()
        try await camera.value
        await close.value
        XCTAssertEqual(destroyed.count, 1)
        XCTAssertThrowsError(try startCamera(manager))
    }

    @MainActor
    func testNativePreviewBindingDoesNotBlockMainThreadDuringCameraStartup() async throws {
        let entered = expectation(description: "Native camera call entered")
        let attached = expectation(description: "Preview attached after camera call returns")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let engine = BlockingCameraAgoraEngine(onCameraStart: {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        }, onPreview: { attached.fulfill() })
        let manager = makeManager(engine)
        try await manager.initialize()
        let camera = Task.detached { try self.startCamera(manager) }
        await fulfillment(of: [entered], timeout: 2)
        let view = NSView()
        let start = ContinuousClock.now
        try manager.attachCameraPreview(to: view, contentMode: .fit, mirrored: false)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
        gate.signal()
        try await camera.value
        await fulfillment(of: [attached], timeout: 2)
        try manager.detachCameraPreview(from: view)
        await manager.destroy()
    }

    @MainActor
    func testFormatRestartPreservesEngineDeviceAndBoundCanvas() async throws {
        let engine = BlockingCameraAgoraEngine(onCameraStart: {})
        let destroyed = CameraEngineDestruction()
        let manager = makeManager(engine, destroy: { destroyed.record() })
        try await manager.initialize()
        try startCamera(manager)
        let view = NSView()
        try manager.attachCameraPreview(to: view, contentMode: .fit, mirrored: true)
        let updated = try VideoFormat(width: 8, height: 4, pixelFormat: .nv12)
        try manager.updateCameraCapture(videoFormat: updated, frameRate: 24)
        XCTAssertEqual(engine.configurations, [
            RtcCameraConfiguration(deviceID: "camera", width: 4, height: 4, frameRate: 30),
            RtcCameraConfiguration(deviceID: "camera", width: 8, height: 4, frameRate: 24)
        ])
        XCTAssertEqual(engine.canvasUpdates, 1, "Format changes must retain the existing canvas")
        XCTAssertEqual(destroyed.count, 0)
        // Updating encoding preferences without capture changes must not restart the camera.
        try manager.updateCameraCapture(videoFormat: updated, frameRate: 24)
        XCTAssertEqual(engine.configurations.count, 2)
        await manager.destroy()
        XCTAssertEqual(destroyed.count, 1)
    }

    func testFailedFormatRestartRestoresPreviousCaptureAndAllowsRetry() async throws {
        let engine = BlockingCameraAgoraEngine(onCameraStart: {}, failingStarts: [2])
        let manager = makeManager(engine)
        try await manager.initialize()
        try startCamera(manager)
        let format = try VideoFormat(width: 8, height: 4, pixelFormat: .nv12)
        XCTAssertThrowsError(try manager.updateCameraCapture(videoFormat: format, frameRate: 24))
        XCTAssertEqual(engine.configurations.map { $0.width }, [4, 8, 4])
        XCTAssertEqual(engine.configurations.map { $0.frameRate }, [30, 24, 30])
        try manager.updateCameraCapture(videoFormat: format, frameRate: 24)
        XCTAssertEqual(engine.configurations.map { $0.width }, [4, 8, 4, 8])
        await manager.destroy()
    }

    func testFailedFormatRestorationReportsRuntimeFailure() async throws {
        let engine = BlockingCameraAgoraEngine(onCameraStart: {}, failingStarts: [2, 3])
        let failed = expectation(description: "Unusable camera reports runtime failure")
        let manager = makeManager(engine)
        try await manager.initialize()
        try manager.startCameraCapture(
            configuration: RtcCameraConfiguration(deviceID: "camera", width: 4, height: 4, frameRate: 30),
            previewReadyListener: {}, errorListener: { _ in failed.fulfill() }
        )
        XCTAssertThrowsError(try manager.updateCameraCapture(
            videoFormat: VideoFormat(width: 8, height: 4, pixelFormat: .nv12), frameRate: 24
        ))
        await fulfillment(of: [failed], timeout: 2)
        await manager.destroy()
    }

    func testInvalidCaptureUpdateDoesNotInterruptActiveCamera() async throws {
        let engine = BlockingCameraAgoraEngine(onCameraStart: {})
        let manager = makeManager(engine)
        try await manager.initialize()
        try startCamera(manager)
        for (format, fps) in [
            (try VideoFormat(width: 8, height: 4, pixelFormat: .bgra), 30),
            (try VideoFormat(width: 7, height: 4, pixelFormat: .nv12), 30),
            (try VideoFormat(width: 8, height: 4, pixelFormat: .nv12), 0),
            (try VideoFormat(width: 8, height: 4, pixelFormat: .nv12), Int(Int32.max) + 1)
        ] {
            XCTAssertThrowsError(try manager.updateCameraCapture(videoFormat: format, frameRate: fps)) {
                XCTAssertEqual(($0 as? XmaxError)?.code, .invalidConfiguration)
            }
        }
        XCTAssertEqual(engine.configurations.count, 1)
        await manager.destroy()
    }

    private func makeManager(
        _ engine: BlockingCameraAgoraEngine, destroy: @escaping @Sendable () -> Void = {}
    ) -> RtcManager {
        let platform = AgoraRtcPlatform(engine: engine.vendor, cameraEvents: RtcCameraEventSink(), roomEngine: engine, cameraEngine: engine)
        return RtcManager(engineManager: RtcEngineManager(
            appID: "test", makeEngine: { _ in platform }, destroyEngine: destroy
        ))
    }

    private func startCamera(_ manager: RtcManager) throws {
        try manager.startCameraCapture(
            configuration: RtcCameraConfiguration(deviceID: "camera", width: 4, height: 4, frameRate: 30),
            previewReadyListener: {}, errorListener: { _ in }
        )
    }
}

private final class CameraEngineDestruction: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private final class BlockingCameraAgoraEngine: AgoraRtcCameraEngine, AgoraRtcRoomEngine, @unchecked Sendable {
    let vendor = AgoraRtcEngineKit()
    private let onCameraStart: @Sendable () -> Void
    private let onLeave: @Sendable () -> Void
    private let onPreview: @Sendable () -> Void
    private let onJoin: @Sendable () -> Void
    private let stateLock = NSLock()
    private var returned = false
    private var storedConfigurations: [RtcCameraConfiguration] = []
    private var storedCanvasUpdates = 0
    private let failingStarts: Set<Int>
    private let failingEncoderCalls: Set<Int>
    var configurations: [RtcCameraConfiguration] { stateLock.withLock { storedConfigurations } }
    var canvasUpdates: Int { stateLock.withLock { storedCanvasUpdates } }
    var cameraReturned: Bool { stateLock.withLock { returned } }
    private var storedEncodedMirrors: [AgoraVideoMirrorMode] = []
    var encodedMirrors: [AgoraVideoMirrorMode] { stateLock.withLock { storedEncodedMirrors } }

    func setVideoEncoderConfiguration(_ config: AgoraVideoEncoderConfiguration) -> Int32 {
        stateLock.withLock {
            storedEncodedMirrors.append(config.mirrorMode)
            return failingEncoderCalls.contains(storedEncodedMirrors.count) ? -1 : 0
        }
    }
    func setVideoEncoderConfigurationEx(_ config: AgoraVideoEncoderConfiguration, connection: AgoraRtcConnection) -> Int32 {
        setVideoEncoderConfiguration(config)
    }

    init(onCameraStart: @escaping @Sendable () -> Void,
         onLeave: @escaping @Sendable () -> Void = {},
         onPreview: @escaping @Sendable () -> Void = {},
         onJoin: @escaping @Sendable () -> Void = {},
         failingStarts: Set<Int> = [], failingEncoderCalls: Set<Int> = []) {
        self.failingStarts = failingStarts
        self.failingEncoderCalls = failingEncoderCalls
        self.onCameraStart = onCameraStart
        self.onLeave = onLeave
        self.onPreview = onPreview
        self.onJoin = onJoin
    }

    func enableLocalVideo(_ enabled: Bool) -> Int32 { 0 }
    func startCameraCapture(_ sourceType: AgoraVideoSourceType, config: AgoraCameraCapturerConfiguration?) -> Int32 {
        onCameraStart()
        return stateLock.withLock {
            returned = true
            if let config {
                storedConfigurations.append(RtcCameraConfiguration(
                    deviceID: config.deviceId ?? "", width: Int(config.dimensions.width),
                    height: Int(config.dimensions.height), frameRate: Int(config.frameRate)
                ))
            }
            return failingStarts.contains(storedConfigurations.count) ? -1 : 0
        }
    }
    func stopCameraCapture(_ sourceType: AgoraVideoSourceType) -> Int32 { 0 }
    func startPreview(_ sourceType: AgoraVideoSourceType) -> Int32 { 0 }
    func stopPreview(_ sourceType: AgoraVideoSourceType) -> Int32 { 0 }
    func setupLocalVideo(_ local: AgoraRtcVideoCanvas?) -> Int32 {
        stateLock.withLock { storedCanvasUpdates += 1 }
        if local?.view != nil { onPreview() }
        return 0
    }
    var audioDelegate: (any AgoraAudioFrameDelegate)?
    func setAudioFrameDelegate(_ delegate: (any AgoraAudioFrameDelegate)?) -> Bool {
        audioDelegate = delegate
        return true
    }
    func setPlaybackAudioFrameBeforeMixingParametersWithSampleRate(
        _ sampleRate: Int, channel: Int, samplesPerCall: Int
    ) -> Int32 { 0 }

    func setVideoFrameDelegate(_ delegate: (any AgoraVideoFrameDelegate)?) -> Bool { true }
    func joinChannelEx(
        byToken token: String?, channelId: String, userAccount: String,
        delegate: (any AgoraRtcEngineDelegate)?, mediaOptions: AgoraRtcChannelMediaOptions,
        joinSuccess: ((String, UInt, Int) -> Void)?
    ) -> Int32 {
        onJoin()
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
    ) -> Int32 {
        onLeave()
        return 0
    }
}

private extension BlockingCameraAgoraEngine {
    func setDevice(_ type: AgoraMediaDeviceType, deviceId: String) -> Int32 { 0 }
    func updateChannelEx(with options: AgoraRtcChannelMediaOptions, connection: AgoraRtcConnection) -> Int32 { 0 }
    func muteRemoteVideoStreamEx(_ uid: UInt, mute: Bool, connection: AgoraRtcConnection) -> Int32 { 0 }
    func muteRemoteAudioStreamEx(_ uid: UInt, mute: Bool, connection: AgoraRtcConnection) -> Int32 { 0 }
    func adjustUserPlaybackSignalVolumeEx(_ uid: UInt, volume: Int, connection: AgoraRtcConnection) -> Int32 { 0 }
    func sendStreamMessageEx(_ streamId: Int, data: Data, connection: AgoraRtcConnection) -> Int32 { 0 }
    func getUserInfo(byUidEx uid: UInt, connection: AgoraRtcConnection, withError error: UnsafeMutablePointer<AgoraErrorCode>?) -> AgoraUserInfo? { nil }
    func getUserInfo(byUserAccountEx account: String, connection: AgoraRtcConnection, withError error: UnsafeMutablePointer<AgoraErrorCode>?) -> AgoraUserInfo? { nil }
}

import AppKit
@preconcurrency import AgoraRtcKit
import XCTest
@testable import XmaxSDK

/// Exercises both real SDK adapter layers, blocking only the vendor camera call.
final class RtcCameraJoinConcurrencyTests: XCTestCase, @unchecked Sendable {
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
    var cameraReturned: Bool { stateLock.withLock { returned } }

    init(onCameraStart: @escaping @Sendable () -> Void,
         onLeave: @escaping @Sendable () -> Void = {},
         onPreview: @escaping @Sendable () -> Void = {},
         onJoin: @escaping @Sendable () -> Void = {}) {
        self.onCameraStart = onCameraStart
        self.onLeave = onLeave
        self.onPreview = onPreview
        self.onJoin = onJoin
    }

    func enableLocalVideo(_ enabled: Bool) -> Int32 { 0 }
    func startCameraCapture(_ sourceType: AgoraVideoSourceType, config: AgoraCameraCapturerConfiguration?) -> Int32 {
        onCameraStart()
        stateLock.withLock { returned = true }
        return 0
    }
    func stopCameraCapture(_ sourceType: AgoraVideoSourceType) -> Int32 { 0 }
    func startPreview(_ sourceType: AgoraVideoSourceType) -> Int32 { 0 }
    func stopPreview(_ sourceType: AgoraVideoSourceType) -> Int32 { 0 }
    func setupLocalVideo(_ local: AgoraRtcVideoCanvas?) -> Int32 {
        if local?.view != nil { onPreview() }
        return 0
    }
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

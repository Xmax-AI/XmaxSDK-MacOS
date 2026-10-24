import CoreMedia
import XCTest
@testable import XmaxSDK

@MainActor
final class ParallelCameraStartupTests: XCTestCase {
    private let format = RealtimeVideoFormat(width: 4, height: 4, fps: 30)

    func testInitializesBeforeForkAndJoinsWhileCameraIsBlockedWithoutPublishingEarly() async throws {
        let engine = CameraStartupGate(), camera = CameraStartupGate(), join = CameraStartupGate()
        let rtc = RtcManagingStub(initializationHandler: { try await engine.wait() },
                                  joinRoomHandler: { _ in try await join.wait() })
        let capture = capture(start: { try? await camera.wait() })
        let parts = components(rtc: rtc, capture: capture)
        var local: RealtimeMediaStream?
        let snapshots = StartupSnapshots()
        await parts.manager.setLaunchTimingListener { snapshots.values.append($0) }
        let task = Task { try await start(parts.manager) { local = $0 } }
        try await waitUntil { rtc.calls.contains(.initialize) }
        XCTAssertTrue(capture.calls.isEmpty)
        XCTAssertTrue(parts.session.calls.isEmpty)
        await engine.ready()
        try await waitUntil { !capture.calls.isEmpty && rtc.calls.contains(where: isJoin) }
        XCTAssertNil(local)
        XCTAssertFalse(rtc.calls.contains(.publishLocalVideo))
        await camera.ready()
        try await waitUntil { local != nil }
        try await waitUntil { snapshots.values.last?.cameraMs != nil }
        XCTAssertNil(snapshots.values.last?.rtcJoinMs, "Camera timing must arrive without waiting for RTC join")
        XCTAssertFalse(rtc.calls.contains(.publishLocalVideo), "Capture alone cannot publish before join succeeds")
        await join.ready()
        try await finishGeneration(rtc)
        let remote = try await task.value
        XCTAssertNotNil(remote.videoTrack)
        XCTAssertEqual(rtc.calls.filter { $0 == .initialize }.count, 1)
        XCTAssertTrue(rtc.calls.contains(.publishLocalVideo))
        let state = await parts.manager.currentState
        XCTAssertEqual(state.connectionState, .generating)
        try await waitUntil { snapshots.values.last?.totalMs != nil }
        XCTAssertNotNil(snapshots.values.last?.cameraMs)
        XCTAssertNotNil(snapshots.values.last?.sessionMs)
        XCTAssertNotNil(snapshots.values.last?.rtcJoinMs)
        XCTAssertNotNil(snapshots.values.last?.publishMs)
        XCTAssertNotNil(snapshots.values.last?.firstFrameMs)
        // No local preview was attached and no local raw frame was delivered.
        await parts.manager.close()
        XCTAssertEqual(rtc.calls.filter { $0 == .destroy }.count, 1)
    }

    func testJoinedRoomWaitsForCameraBeforePublishing() async throws {
        let camera = CameraStartupGate()
        let rtc = RtcManagingStub()
        let parts = components(rtc: rtc, capture: capture(start: { try? await camera.wait() }))
        var localCount = 0
        let task = Task { try await start(parts.manager) { _ in localCount += 1 } }
        try await waitUntil { rtc.calls.contains(where: isJoin) && !parts.capture.calls.isEmpty }
        XCTAssertFalse(rtc.calls.contains(.publishLocalVideo))
        XCTAssertEqual(localCount, 0)
        await camera.ready()
        try await finishGeneration(rtc)
        _ = try await task.value
        XCTAssertEqual(localCount, 1)
        await parts.manager.close()
    }

    func testCameraFailureCancelsPendingJoinAndReleasesBothBranches() async throws {
        let join = CameraStartupGate()
        let rtc = RtcManagingStub(joinRoomHandler: { _ in try await join.wait() })
        let capture = capture(start: {})
        let permission = PermissionManagingStub(cameraError: XmaxError(code: .cameraPermissionDenied, message: "Denied"))
        let parts = components(rtc: rtc, capture: capture, permission: permission)
        do {
            _ = try await start(parts.manager) { _ in XCTFail("Failed camera must not be delivered") }
            XCTFail("Expected startup failure")
        } catch {}
        let state = await parts.manager.currentState
        XCTAssertEqual(state.connectionState, .idle)
        XCTAssertFalse(rtc.calls.contains(.publishLocalVideo))
        XCTAssertEqual(rtc.calls.filter { $0 == .destroy }.count, 1)
        if parts.session.calls.contains(.createSession(.x2_1_1_preview_cn)) {
            XCTAssertTrue(parts.session.calls.contains(.closeSession("session")))
        }
    }

    func testCloudFailureCancelsCameraAndReleasesEngine() async throws {
        let blockedCamera = CameraStartupGate()
        let rtc = RtcManagingStub()
        let capture = capture(start: { try? await blockedCamera.wait() })
        let parts = components(rtc: rtc, capture: capture,
                               sessionError: XmaxError(code: .sessionError, message: "Unavailable"))
        do {
            _ = try await start(parts.manager) { _ in XCTFail("Cancelled capture must not be delivered") }
            XCTFail("Expected startup failure")
        } catch {}
        XCTAssertFalse(rtc.calls.contains(.publishLocalVideo))
        XCTAssertEqual(rtc.calls.filter { $0 == .destroy }.count, 1)
        let track = await parts.media.currentTrack
        XCTAssertNil(track)
    }

    func testCloseCancelsBothBranchesAndLateLocalStreamCannotEscape() async throws {
        let camera = CameraStartupGate(), join = CameraStartupGate()
        let rtc = RtcManagingStub(joinRoomHandler: { _ in try await join.wait() })
        let parts = components(rtc: rtc, capture: capture(start: { try? await camera.wait() }))
        let task = Task { try await start(parts.manager) { _ in XCTFail("Closed startup must not deliver local capture") } }
        try await waitUntil { !parts.capture.calls.isEmpty && rtc.calls.contains(where: isJoin) }
        await parts.manager.close()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertTrue(parts.capture.calls.contains(.stop))
        XCTAssertTrue(parts.session.calls.contains(.closeSession("session")))
        XCTAssertEqual(rtc.calls.filter { $0 == .destroy }.count, 1)
        XCTAssertFalse(rtc.calls.contains(.publishLocalVideo))
        let state = await parts.manager.currentState
        XCTAssertEqual(state.connectionState, .idle)
    }

    func testExistingLocalStreamIsRejectedWithoutTearingItDown() async throws {
        let parts = components(rtc: RtcManagingStub(), capture: capture(start: {}))
        let local = try await parts.manager.createLocalCameraStream(videoFormat: format, deviceID: nil)
        do {
            _ = try await start(parts.manager) { _ in XCTFail("Should reject") }
            XCTFail("Expected conflict")
        } catch {}
        let owns = await parts.media.owns(local)
        XCTAssertTrue(owns)
        XCTAssertFalse(parts.rtc.calls.contains(.destroy))
        await parts.manager.close()
    }

    private func start(_ manager: XmaxRealtimeManager,
                       listener: @escaping @MainActor @Sendable (RealtimeMediaStream) -> Void) async throws -> RealtimeMediaStream {
        try await manager.startCameraGeneration(videoFormat: format, deviceID: nil, useMicrophone: false,
                                                context: RealtimeContext(prompt: "test"), faceRestoration: false,
                                                localStreamListener: listener)
    }

    private func finishGeneration(_ rtc: RtcManagingStub) async throws {
        try await waitUntil { rtc.calls.contains { if case .sendRoomMessage = $0 { true } else { false } } }
        rtc.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room", userID: "bot"))
        try await waitUntil {
            rtc.calls.contains { if case .setRemoteVideoFrameListener(_, enabled: true) = $0 { true } else { false } }
        }
        try rtc.emitRemoteVideoFrame(width: 4, height: 4, presentationTimeStamp: .zero)
    }

    private func isJoin(_ call: RtcManagingCall) -> Bool {
        if case .joinRoom = call { true } else { false }
    }

    private func capture(start: @escaping @Sendable () async -> Void) -> CameraCaptureManagingStub {
        CameraCaptureManagingStub(devices: [CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)],
                                  startHandler: start)
    }

    private func components(rtc: RtcManagingStub, capture: CameraCaptureManagingStub,
                            permission: PermissionManagingStub = PermissionManagingStub(),
                            sessionError: (any Error)? = nil)
    -> (manager: XmaxRealtimeManager, media: MediaController, rtc: RtcManagingStub,
        capture: CameraCaptureManagingStub, session: RealtimeSessionServicingStub) {
        let errors = RealtimeErrorHandler(), timing = RealtimeTiming()
        let service = MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4))
        let render = RenderController(rtcManager: rtc, errorListener: { errors.forward($0, target: .connection) })
        let stream = StreamController(rtcManager: rtc, errorListener: { errors.forward($0, target: .connection) },
                                      remoteStreamListener: { try render.setRemoteStream($0) }, timing: timing)
        let camera = CameraController(rtcManager: rtc, permissionManager: permission, mediaService: service, captureManager: capture)
        let media = MediaController(rtcManager: rtc, cameraController: camera)
        let session = RealtimeSessionServicingStub(session: RealtimeSession(
            id: "session", userID: "user", status: "ACTIVE",
            connection: RealtimeSessionConnection(roomID: "room", userID: "user", token: "token", botName: "bot"), closeReason: nil
        ), createError: sessionError)
        let connection = XmaxRealtimeConnectionManager(sessionService: session, interactionController: media,
                                                       renderController: render, streamController: stream, timing: timing)
        let generation = XmaxRealtimeGenerationManager(interactionController: media, streamController: stream, renderController: render)
        return (XmaxRealtimeManager(options: RealtimeConfiguration(model: .x2_1_1_preview_cn), streamController: stream,
                                    mediaController: media, renderController: render, mediaService: service,
                                    connectionManager: connection, errorHandler: errors, generationManager: generation, timing: timing),
                media, rtc, capture, session)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw XmaxError(code: .timeout, message: "Parallel startup test timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor private final class StartupSnapshots {
    var values: [RealtimeLaunchTiming] = []
}

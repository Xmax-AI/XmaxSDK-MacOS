//
//  ExternalVideoIntegrationTests.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import XCTest
@testable import XmaxSDK

@MainActor
final class ExternalVideoIntegrationTests: XCTestCase {
    func testCloseReleasesCaptureWhileRTCDisconnectIsBlocked() async throws {
        let gate = CaptureShutdownGate()
        let rtc = RtcManagingStub(leaveRoomHandler: { await gate.wait() })
        let capture = CameraCaptureManagingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)), captureManager: capture
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        let local = try await components.manager.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), deviceID: nil, useMicrophone: true
        )
        _ = try await components.manager.connect(localStream: local)
        let close = Task { await components.manager.close() }
        try await waitUntil { await gate.isWaiting }
        XCTAssertEqual(capture.calls, [.start("camera"), .stop])
        XCTAssertNil(camera.currentTrack)
        XCTAssertTrue(rtc.calls.contains(.stopAudioCapture))
        XCTAssertFalse(rtc.calls.contains(.destroy))
        await gate.release()
        await close.value
        XCTAssertEqual(rtc.calls.filter { $0 == .destroy }.count, 1)
    }

    func testCloseDuringCameraStartupStopsCaptureBeforeLateStartupReturns() async throws {
        let gate = CaptureShutdownGate()
        let rtc = RtcManagingStub()
        let capture = CameraCaptureManagingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ], startHandler: { await gate.wait() })
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)), captureManager: capture
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        let start = Task {
            try await components.manager.createLocalCameraStream(
                videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), deviceID: nil
            )
        }
        try await waitUntil { await gate.isWaiting }
        let close = Task { await components.manager.close() }
        try await waitUntil { capture.calls.contains(.stop) }
        XCTAssertNil(camera.currentTrack)
        XCTAssertNil(capture.currentFrameListener)
        await gate.release()
        do {
            _ = try await start.value
            XCTFail("Late startup must not succeed after close")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
        await close.value
        XCTAssertNil(camera.currentTrack)
        XCTAssertNil(capture.currentFrameListener)
        let state = await components.manager.currentState
        XCTAssertEqual(state.connectionState, .idle)
    }

    func testEarlyCaptureStopReleasesCameraWithoutDestroyingRTCAndFinalStopIsIdempotent() async throws {
        let capture = CameraCaptureManagingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let rtc = RtcManagingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)), captureManager: capture
        )
        let media = MediaController(rtcManager: rtc, cameraController: camera)
        _ = try await media.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), deviceID: nil
        )
        await media.stopLocalCapture()
        await media.stopLocalCapture()
        XCTAssertEqual(capture.calls, [.start("camera"), .stop])
        XCTAssertNil(camera.currentTrack)
        XCTAssertFalse(rtc.calls.contains(.destroy), "RTC must survive until remote disconnect")
        await media.stopLocalStream()
        XCTAssertEqual(capture.calls, [.start("camera"), .stop])
        XCTAssertEqual(rtc.calls.filter { $0 == .destroy }.count, 1)
        _ = try await media.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), deviceID: nil
        )
        await media.stopLocalCapture()
        await media.stopLocalStream()
        XCTAssertEqual(capture.calls, [.start("camera"), .stop, .start("camera"), .stop])
    }


    func testExternalStopDoesNotAdvanceCameraPreviewReadiness() async throws {
        let rtc = RtcManagingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)),
            captureManager: CameraCaptureManagingStub(devices: [
                CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
            ])
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        _ = try await components.manager.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), deviceID: nil
        )
        try await components.manager.stopExternalVideoStream()
        let state = await components.manager.currentState
        XCTAssertEqual(state.connectionState, .preparing)
        XCTAssertNotNil(camera.currentTrack)
        await components.manager.close()
    }

    func testBindingIsReadyWithoutFramesOrPreviewAndEnforcesSingleMediaOwnership() async throws {
        let components = makeComponents()
        let manager: any XmaxRealtimeManaging = components.manager
        let source = ExternalSourceStub()
        let local = try await manager.createExternalVideoStream(source: source)
        let ready = await manager.currentState
        XCTAssertEqual(ready.connectionState, .ready)
        XCTAssertFalse(source.sink?.isRequestingFrames ?? true)
        let ownsLocal = await components.media.owns(local)
        XCTAssertTrue(ownsLocal)
        do {
            _ = try await manager.createExternalVideoStream(source: ExternalSourceStub())
            XCTFail("Expected single media ownership")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        XCTAssertEqual(source.stops, 0)
        try await manager.stopExternalVideoStream()
        try await manager.stopExternalVideoStream()
        let idle = await manager.currentState
        XCTAssertEqual(idle.connectionState, .idle)
        XCTAssertEqual(source.stops, 1)
        XCTAssertEqual(components.rtc.calls.filter { $0 == .destroy }.count, 1)
    }

    func testFramesFlowDuringGenerationStartupAndDisconnectRetainsTheBinding() async throws {
        let components = makeComponents()
        let manager = components.manager
        let source = ExternalSourceStub()
        let local = try await manager.createExternalVideoStream(source: source, videoFormat: nil)
        let sink = try XCTUnwrap(source.sink)
        let generation = Task {
            try await manager.startGeneration(
                localStream: local,
                context: RealtimeContext(prompt: "test"), faceRestoration: false
            )
        }
        try await waitUntil { sink.isRequestingFrames }
        sink.pushVideo(try ExternalVideoControllerTests.makeBuffer(), timestampUs: 1)
        XCTAssertTrue(components.rtc.calls.contains(.pushExternalVideoFrame))
        components.rtc.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room", userID: "bot"))
        try await waitUntil {
            components.rtc.calls.contains {
                if case .setRemoteVideoFrameListener(_, enabled: true) = $0 { return true }
                return false
            }
        }
        try components.rtc.emitRemoteVideoFrame(width: 4, height: 4, presentationTimeStamp: .zero)
        let remote = try await generation.value
        XCTAssertNotNil(remote.videoTrack)
        let generating = await manager.currentState
        XCTAssertEqual(generating.connectionState, .generating)
        XCTAssertTrue(sink.isRequestingFrames)
        do {
            try await manager.stopExternalVideoStream()
            XCTFail("Expected disconnect requirement")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }
        XCTAssertEqual(source.stops, 0)

        await manager.disconnect()
        XCTAssertFalse(sink.isRequestingFrames)
        XCTAssertNotNil(source.sink)
        XCTAssertEqual(source.stops, 0)
        XCTAssertFalse(components.rtc.calls.contains(.destroy))
        let ownedAfterDisconnect = await components.media.owns(local)
        XCTAssertTrue(ownedAfterDisconnect)
        try await manager.stopExternalVideoStream()
        XCTAssertEqual(source.stops, 1)
        await manager.close()
        XCTAssertEqual(components.rtc.calls.filter { $0 == .destroy }.count, 1)
    }

    func testSourceFailureCleansUpAndOldErrorsCannotAffectTheNextBinding() async throws {
        let components = makeComponents()
        let source = ExternalSourceStub()
        _ = try await components.manager.createExternalVideoStream(source: source, videoFormat: nil)
        let oldSink = try XCTUnwrap(source.sink)
        oldSink.reportError(XmaxError(code: .mediaError, message: "Camera disconnected"))
        try await waitUntil { source.stops == 1 }
        let failed = await components.manager.currentState
        XCTAssertEqual(failed.connectionState, .idle)
        guard case let .failure(error) = failed.reason else {
            return XCTFail("Expected external media failure")
        }
        XCTAssertEqual(error.code, .mediaError)
        let next = ExternalSourceStub()
        _ = try await components.manager.createExternalVideoStream(source: next, videoFormat: nil)
        oldSink.reportError(XmaxError(code: .mediaError, message: "Late error"))
        await Task.yield()
        let ready = await components.manager.currentState
        XCTAssertEqual(ready.connectionState, .ready)
        XCTAssertEqual(next.stops, 0)
        await components.manager.close()
    }

    func testCloseCancelsSuspendedSourceBindingAndAllowsReuse() async throws {
        let components = makeComponents()
        let source = ExternalSourceStub()
        source.startHandler = { try await Task.sleep(for: .seconds(30)) }
        let creation = Task {
            try await components.manager.createExternalVideoStream(source: source, videoFormat: nil)
        }
        try await waitUntil { source.sink != nil }
        await components.manager.close()
        do {
            _ = try await creation.value
            XCTFail("Expected cancelled creation")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(source.lastSink?.isRequestingFrames ?? true)
        let state = await components.manager.currentState
        XCTAssertEqual(state.connectionState, .idle)
        _ = try await components.manager.createExternalVideoStream(source: ExternalSourceStub(), videoFormat: nil)
        await components.manager.close()
    }

    func testLatestGenerationRequestKeepsConnectionAndExternalInput() async throws {
        let components = makeComponents()
        let manager = components.manager
        let source = ExternalSourceStub()
        let local = try await manager.createExternalVideoStream(source: source)
        let first = Task {
            try await manager.startGeneration(localStream: local, context: RealtimeContext(prompt: "first"))
        }
        try await waitUntil { self.roomMessages(components.rtc, event: "start").count == 1 }
        let latest = Task {
            try await manager.startGeneration(context: RealtimeContext(prompt: "latest"))
        }
        try await waitUntil { self.roomMessages(components.rtc, event: "start").count == 2 }
        do { _ = try await first.value; XCTFail("Replaced startup must be cancelled") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
        XCTAssertEqual(source.stops, 0)
        XCTAssertFalse(components.rtc.calls.contains(.leaveRoom))
        XCTAssertFalse(components.rtc.calls.contains(.destroy))
        let joins = components.rtc.calls.filter { if case .joinRoom = $0 { true } else { false } }
        XCTAssertEqual(joins.count, 1)
        let starts = roomMessages(components.rtc, event: "start")
        XCTAssertEqual((starts.last?["params"] as? [String: Any])?["prompt"] as? String, "latest")
        components.rtc.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room", userID: "bot"))
        try await waitUntil {
            components.rtc.calls.contains { if case .setRemoteVideoFrameListener(_, enabled: true) = $0 { true } else { false } }
        }
        try components.rtc.emitRemoteVideoFrame(width: 4, height: 4, presentationTimeStamp: .zero)
        try await latest.value
        let state = await manager.currentState
        let owns = await components.media.owns(local)
        XCTAssertEqual(state.connectionState, .generating)
        XCTAssertTrue(owns)
        await manager.close()
        XCTAssertEqual(source.stops, 1)
    }

    func testExternalAspectRatioUsesSeparateGenerationCanvasAndContainPadding() async throws {
        let service = MediaService()
        let components = makeComponents(mediaService: service)
        let source = ExternalSourceStub(videoFormat: RealtimeVideoFormat(width: 640, height: 480, fps: 30))
        let local = try await components.manager.createExternalVideoStream(source: source)
        let generation = Task {
            try await components.manager.startGeneration(localStream: local, context: RealtimeContext(prompt: "test"))
        }
        try await waitUntil { !self.roomMessages(components.rtc, event: "start").isEmpty }
        let event = try XCTUnwrap(roomMessages(components.rtc, event: "start").first)
        let params = try XCTUnwrap(event["params"] as? [String: Any])
        XCTAssertEqual(local.videoTrack?.videoFormat?.size, CGSize(width: 640, height: 480))
        XCTAssertEqual(params["size"] as? [Int], [1920, 1024])
        XCTAssertEqual(params["padding"] as? String, "contain")
        await components.manager.close()
        do { _ = try await generation.value; XCTFail("Expected close cancellation") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
    }

    private func roomMessages(_ rtc: RtcManagingStub, event: String) -> [[String: Any]] {
        rtc.calls.compactMap { call in
            guard case .sendRoomMessage(let text) = call,
                  let data = text.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  message["event"] as? String == event else { return nil }
            return message
        }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                throw XmaxError(code: .timeout, message: "External input test condition timed out")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeComponents(
        rtc: RtcManagingStub = RtcManagingStub(),
        camera: (any CameraControlling)? = nil,
        mediaService: (any MediaServicing)? = nil
    ) -> (manager: XmaxRealtimeManager, media: MediaController, rtc: RtcManagingStub) {
        let errors = XmaxRealtimeErrorManager()
        let timing = RealtimeTiming()
        let service: any MediaServicing = mediaService ?? MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4))
        let render = RenderController(rtcManager: rtc, errorListener: { errors.forward($0, target: .connection) })
        let stream = StreamController(
            rtcManager: rtc,
            errorListener: { errors.forward($0, target: .connection) },
            remoteStreamListener: { try render.setRemoteStream($0) }, timing: timing
        )
        let media: MediaController
        if let camera {
            media = MediaController(rtcManager: rtc, cameraController: camera)
        } else {
            media = MediaController(
                rtcManager: rtc, mediaService: service,
                videoFrameListener: { try stream.pushLocalVideoFrame($0) },
                requestingFrames: { stream.hasGenerationTask },
                errorListener: { errors.forward($0, target: .all) },
                interactionListener: { try await stream.sendTracks(taskID: $0, points: $1) }
            )
        }
        let session = RealtimeSession(
            id: "session", userID: "user", status: "ACTIVE",
            connection: RealtimeSessionConnection(roomID: "room", userID: "user", token: "token", botName: "bot"),
            closeReason: nil
        )
        let connection = XmaxRealtimeConnectionManager(
            sessionService: RealtimeSessionServicingStub(session: session),
            interactionController: media, renderController: render, streamController: stream, timing: timing, mediaService: service, errorManager: errors
        )
        let generation = XmaxRealtimeGenerationManager(interactionController: media, streamController: stream, renderController: render, timing: timing)
        let manager = XmaxRealtimeManager(
            options: RealtimeConfiguration(model: .x2_1_1_preview_cn),
            streamController: stream, mediaController: media, renderController: render,
            mediaService: service, connectionManager: connection, errorManager: errors,
            generationManager: generation, timing: timing
        )
        return (manager, media, rtc)
    }
}

private actor CaptureShutdownGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

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
    func testSDKCameraAndMicrophoneUseCustomRTCTracks() async throws {
        let capture = CameraCaptureControllingStub(
            devices: [CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)],
            automaticallyReady: true
        )
        let microphone = MicrophoneCaptureControllingStub()
        let components = makeComponents(capture: (capture, microphone))
        let manager = components.manager
        var readings: [Float?] = []
        await manager.setMicrophoneLevelListener { readings.append($0) }
        let local = try await manager.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30),
            microphone: .systemDefault
        )
        XCTAssertEqual(microphone.calls, [.select(nil)])
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: XCTUnwrap(local.videoTrack))?.attach(to: view, contentMode: .fit)
        _ = try await manager.connect(localStream: local)
        microphone.emitLevel(0.5)
        XCTAssertEqual(readings, [nil, 0.5])
        await manager.setMicrophoneLevelListener(nil)
        microphone.emitLevel(0.9)
        XCTAssertEqual(readings, [nil, 0.5])
        let audio = AudioFrame(data: Data(count: 960), timestampUs: 1_000_000)
        try microphone.emitAudio(audio)
        XCTAssertTrue(components.rtc.calls.contains(.pushExternalAudioFrame(audio)))
        let generation = Task { try await manager.startGeneration(context: RealtimeContext(prompt: "test")) }
        try await waitUntil { !self.roomMessages(components.rtc, event: "start").isEmpty }
        let video = try VideoFrame(
            format: VideoFormat(width: 4, height: 4, pixelFormat: .bgra),
            timestampUs: 1_000_000,
            planes: [VideoFramePlane(data: Data(count: 64), stride: 16)]
        )
        try capture.emitVideo(video)
        try await waitUntil { components.rtc.calls.contains(.pushExternalVideoFrame) }
        XCTAssertTrue(components.rtc.calls.contains(.useExternalVideoSource))
        let remote = RemoteStream(roomID: "room", userID: "bot")
        components.rtc.emitRemoteVideoAvailable(stream: remote)
        try await waitUntil { components.rtc.calls.contains(.setRemoteVideoFrameListener(remote, enabled: true)) }
        try components.rtc.emitRemoteVideoFrame(width: 4, height: 4)
        try await generation.value
        await manager.close()
        XCTAssertEqual(microphone.calls, [.select(nil), .start, .stop])
        XCTAssertEqual(capture.calls, [.start("camera"), .stop])
    }

    func testMicrophoneListingDoesNotInitializeRTCOrRequestCapturePermission() async throws {
        let input = MicrophoneDevice(id: "stable-input-uid", name: "USB Microphone", isDefault: true)
        let rtc = RtcManagingStub(initializationError: XmaxError(code: .rtcError, message: "RTC must stay idle"))
        let permissions = PermissionManagingStub()
        let capture = CameraCaptureControllingStub(devices: [])
        let camera = CameraController(
            rtcManager: rtc,
            permissionManager: permissions,
            mediaService: MediaService(),
            cameraCapture: capture,
            microphoneCapture: MicrophoneCaptureControllingStub()
        )
        let manager: any XmaxRealtimeManaging = makeComponents(
            rtc: rtc,
            camera: camera,
            microphoneDevices: { [input] }
        ).manager
        let devices = await manager.listMicrophoneDevices()
        XCTAssertEqual(devices, [input])
        XCTAssertTrue(rtc.calls.isEmpty)
        XCTAssertTrue(capture.calls.isEmpty)
        XCTAssertEqual(permissions.cameraRequestCount, 0)
        XCTAssertEqual(permissions.microphoneRequestCount, 0)
        let state = await manager.currentState
        XCTAssertEqual(state.connectionState, .idle)
        await manager.close()
    }

    func testCancellingMicrophoneEnableAfterPublicationRollsBackAudioOnly() async throws {
        let entered = expectation(description: "Audio publication reached")
        let gate = DispatchSemaphore(value: 0)
        let rtc = RtcManagingStub(publishLocalAudioHandler: {
            entered.fulfill()
            gate.wait()
        })
        let capture = CameraCaptureControllingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let microphone = MicrophoneCaptureControllingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)),
            cameraCapture: capture,
            microphoneCapture: microphone
        )
        let manager = makeComponents(rtc: rtc, camera: camera).manager
        let local = try await manager.createLocalCameraStream(videoFormat: .init(width: 4, height: 4, fps: 30))
        _ = try await manager.connect(localStream: local)
        let enable = Task { try await manager.setMicrophoneEnabled(true) }
        await fulfillment(of: [entered], timeout: 2)
        enable.cancel()
        gate.signal()
        do { try await enable.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
        let enabled = await manager.isMicrophoneEnabled
        XCTAssertFalse(enabled)
        let state = await manager.currentState
        XCTAssertEqual(state.connectionState, .connected)
        XCTAssertTrue(camera.currentTrack === local.videoTrack)
        XCTAssertEqual(rtc.calls.filter { $0 == .publishLocalAudio }.count, 1)
        XCTAssertEqual(rtc.calls.filter { $0 == .unpublishLocalAudio }.count, 1)
        XCTAssertTrue(microphone.calls.contains(.stop))
        await manager.close()
    }

    func testMicrophoneChangesBeforeConnectionOnlyUpdateIntent() async throws {
        let rtc = RtcManagingStub()
        let permissions = PermissionManagingStub()
        let device = CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        let microphone = MicrophoneCaptureControllingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: permissions,
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)),
            cameraCapture: CameraCaptureControllingStub(devices: [device], automaticallyReady: true),
            microphoneCapture: microphone
        )
        let manager = makeComponents(rtc: rtc, camera: camera).manager
        let local = try await manager.createLocalCameraStream(videoFormat: .init(width: 4, height: 4, fps: 30))
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: XCTUnwrap(local.videoTrack))?.attach(to: view, contentMode: .fit)
        try await waitUntil { await manager.currentState.connectionState == .ready }
        try await manager.switchMicrophone(to: "usb-input")
        try await manager.setMicrophoneEnabled(true)
        let enabled = await manager.isMicrophoneEnabled
        XCTAssertTrue(enabled)
        XCTAssertEqual(permissions.microphoneRequestCount, 1)
        XCTAssertFalse(microphone.calls.contains(.start))
        XCTAssertFalse(rtc.calls.contains(.publishLocalAudio))
        _ = try await manager.connect(localStream: local)
        XCTAssertTrue(microphone.calls.contains(.start))
        XCTAssertTrue(rtc.calls.contains(.startExternalAudioSource))
        XCTAssertTrue(rtc.calls.contains(.publishLocalAudio))
        await manager.close()
    }

    func testMicrophoneSwitchAndToggleKeepGenerationAndVideoTrack() async throws {
        let rtc = RtcManagingStub()
        let permissions = PermissionManagingStub()
        let capture = CameraCaptureControllingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let microphone = MicrophoneCaptureControllingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: permissions,
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)), cameraCapture: capture,
            microphoneCapture: microphone
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        let manager = components.manager
        let local = try await manager.createLocalCameraStream(videoFormat: .init(width: 4, height: 4, fps: 30))
        _ = try await manager.connect(localStream: local)
        let trackPreparation = try XCTUnwrap(rtc.calls.firstIndex(of: .startExternalAudioSource))
        let roomJoin = try XCTUnwrap(rtc.calls.firstIndex { if case .joinRoom = $0 { true } else { false } })
        XCTAssertLessThan(trackPreparation, roomJoin)
        XCTAssertEqual(microphone.calls, [.select(nil)])
        let generating = Task { try await manager.startGeneration(context: RealtimeContext(prompt: "keep generating")) }
        try await waitUntil { !self.roomMessages(rtc, event: "start").isEmpty }
        let remote = RemoteStream(roomID: "room", userID: "bot")
        rtc.emitRemoteVideoAvailable(stream: remote)
        try await waitUntil { rtc.calls.contains(.setRemoteVideoFrameListener(remote, enabled: true)) }
        try rtc.emitRemoteVideoFrame(width: 4, height: 4)
        try await generating.value
        let before = await manager.currentState
        let signalingCount = rtc.calls.filter { if case .sendRoomMessage = $0 { true } else { false } }.count

        try await manager.switchMicrophone(to: "usb-input")
        XCTAssertEqual(permissions.microphoneRequestCount, 0)
        XCTAssertFalse(microphone.calls.contains(.start))
        try await manager.setMicrophoneEnabled(true)
        try await manager.switchMicrophone(to: nil)
        try await manager.setMicrophoneEnabled(false)
        try await manager.setMicrophoneEnabled(true)
        let after = await manager.currentState
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.connectionState, .generating)
        XCTAssertTrue(camera.currentTrack === local.videoTrack)
        XCTAssertEqual(capture.calls, [.start("camera")])
        XCTAssertTrue(microphone.calls.contains(.select("usb-input")))
        XCTAssertTrue(microphone.calls.contains(.select(nil)))
        XCTAssertEqual(rtc.calls.filter { if case .sendRoomMessage = $0 { true } else { false } }.count, signalingCount)
        await manager.close()
        XCTAssertEqual(rtc.calls.filter { $0 == .publishLocalAudio }.count, 2)
        XCTAssertEqual(rtc.calls.filter { $0 == .unpublishLocalAudio }.count, 2)
        XCTAssertEqual(microphone.calls.filter { $0 == .start }.count, 2)
        XCTAssertEqual(microphone.calls.filter { $0 == .stop }.count, 2)
    }

    func testMicrophonePermissionOrPublicationFailurePreservesVideoAndDisabledIntent() async throws {
        let failure = XmaxError(code: .mediaError, message: "Audio rejected")
        for denyPermission in [true, false] {
            let rtc = RtcManagingStub(publishLocalAudioError: denyPermission ? nil : failure)
            let permissions = PermissionManagingStub(microphoneError: denyPermission ? failure : nil)
            let capture = CameraCaptureControllingStub(devices: [
                CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
            ])
            let microphone = MicrophoneCaptureControllingStub()
            let camera = CameraController(
                rtcManager: rtc, permissionManager: permissions,
                mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)),
                cameraCapture: capture,
                microphoneCapture: microphone
            )
            let manager = makeComponents(rtc: rtc, camera: camera).manager
            let local = try await manager.createLocalCameraStream(videoFormat: .init(width: 4, height: 4, fps: 30))
            _ = try await manager.connect(localStream: local)
            do { try await manager.setMicrophoneEnabled(true); XCTFail("Expected audio error") }
            catch { XCTAssertEqual(error as? XmaxError, failure) }
            let enabled = await manager.isMicrophoneEnabled
            XCTAssertFalse(enabled)
            let state = await manager.currentState
            XCTAssertEqual(state.connectionState, .connected)
            XCTAssertTrue(camera.currentTrack === local.videoTrack)
            XCTAssertEqual(microphone.calls.filter { $0 == .start }.count, denyPermission ? 0 : 1)
            XCTAssertEqual(microphone.calls.filter { $0 == .stop }.count, denyPermission ? 0 : 1)
            await manager.close()
        }
    }

    func testMicrophoneDisableStopsCaptureEvenWhenUnpublicationFailsAndCloseRetries() async throws {
        let failure = XmaxError(code: .rtcError, message: "Unpublication rejected")
        let rtc = RtcManagingStub(unpublishLocalAudioError: failure)
        let capture = CameraCaptureControllingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let microphone = MicrophoneCaptureControllingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)),
            cameraCapture: capture,
            microphoneCapture: microphone
        )
        let manager = makeComponents(rtc: rtc, camera: camera).manager
        let local = try await manager.createLocalCameraStream(
            videoFormat: .init(width: 4, height: 4, fps: 30), microphone: .systemDefault
        )
        _ = try await manager.connect(localStream: local)
        do { try await manager.setMicrophoneEnabled(false); XCTFail("Expected publication error") }
        catch { XCTAssertEqual(error as? XmaxError, failure) }
        let enabled = await manager.isMicrophoneEnabled
        XCTAssertFalse(enabled)
        XCTAssertTrue(microphone.calls.contains(.stop))
        XCTAssertTrue(camera.currentTrack === local.videoTrack)
        await manager.close()
        XCTAssertEqual(rtc.calls.filter { $0 == .unpublishLocalAudio }.count, 2)
        XCTAssertEqual(microphone.calls.filter { $0 == .stop }.count, 1)
    }

    func testCloseDuringMicrophonePermissionCannotStartLateCapture() async throws {
        let gate = CaptureShutdownGate()
        let permissions = PermissionManagingStub(microphoneHandler: { await gate.wait() })
        let rtc = RtcManagingStub()
        let capture = CameraCaptureControllingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let microphone = MicrophoneCaptureControllingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: permissions,
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)), cameraCapture: capture,
            microphoneCapture: microphone
        )
        let manager = makeComponents(rtc: rtc, camera: camera).manager
        let local = try await manager.createLocalCameraStream(videoFormat: .init(width: 4, height: 4, fps: 30))
        _ = try await manager.connect(localStream: local)
        let enable = Task { try await manager.setMicrophoneEnabled(true) }
        try await waitUntil { await gate.isWaiting }
        let close = Task { await manager.close() }
        try await waitUntil { capture.calls.contains(.stop) }
        await gate.release()
        do { try await enable.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
        await close.value
        XCTAssertFalse(microphone.calls.contains(.start))
        XCTAssertFalse(rtc.calls.contains(.publishLocalAudio))
    }

    func testCloseReleasesCaptureWhileRTCDisconnectIsBlocked() async throws {
        let gate = CaptureShutdownGate()
        let rtc = RtcManagingStub(leaveRoomHandler: { await gate.wait() })
        let capture = CameraCaptureControllingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let microphone = MicrophoneCaptureControllingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)), cameraCapture: capture,
            microphoneCapture: microphone
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        let local = try await components.manager.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), camera: .systemDefault, microphone: .systemDefault
        )
        _ = try await components.manager.connect(localStream: local)
        let close = Task { await components.manager.close() }
        try await waitUntil { await gate.isWaiting }
        XCTAssertEqual(capture.calls, [.start("camera"), .stop])
        XCTAssertNil(camera.currentTrack)
        XCTAssertTrue(microphone.calls.contains(.stop))
        XCTAssertFalse(rtc.calls.contains(.destroy))
        await gate.release()
        await close.value
        XCTAssertEqual(rtc.calls.filter { $0 == .destroy }.count, 1)
    }

    func testCloseDuringCameraStartupStopsCaptureBeforeLateStartupReturns() async throws {
        let gate = CaptureShutdownGate()
        let rtc = RtcManagingStub()
        let capture = CameraCaptureControllingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ], startHandler: { await gate.wait() })
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)), cameraCapture: capture,
            microphoneCapture: MicrophoneCaptureControllingStub()
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        let start = Task {
            try await components.manager.createLocalCameraStream(
                videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), camera: .systemDefault
            )
        }
        try await waitUntil { await gate.isWaiting }
        let close = Task { await components.manager.close() }
        try await waitUntil { capture.calls.contains(.stop) }
        XCTAssertNil(camera.currentTrack)
        XCTAssertNil(capture.currentPreviewReadyListener)
        await gate.release()
        do {
            _ = try await start.value
            XCTFail("Late startup must not succeed after close")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
        await close.value
        XCTAssertNil(camera.currentTrack)
        XCTAssertNil(capture.currentPreviewReadyListener)
        let state = await components.manager.currentState
        XCTAssertEqual(state.connectionState, .idle)
    }

    func testCloseDuringCameraConnectionPreventsLocalPublication() async throws {
        let gate = CaptureShutdownGate()
        let rtc = RtcManagingStub(joinRoomHandler: { _ in await gate.wait() })
        let capture = CameraCaptureControllingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)), cameraCapture: capture,
            microphoneCapture: MicrophoneCaptureControllingStub()
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        let local = try await components.manager.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), camera: .systemDefault, microphone: .systemDefault
        )
        let connect = Task { try await components.manager.connect(localStream: local) }
        try await waitUntil { await gate.isWaiting }
        XCTAssertFalse(rtc.calls.contains(.publishLocalVideo))
        let close = Task { await components.manager.close() }
        try await waitUntil { capture.calls.contains(.stop) }
        await gate.release()
        do {
            _ = try await connect.value
            XCTFail("Closing during RTC join must cancel the connection")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
        await close.value
        XCTAssertFalse(rtc.calls.contains(.publishLocalVideo))
        XCTAssertFalse(rtc.calls.contains(.publishLocalAudio))
    }

    func testEarlyCaptureStopReleasesCameraWithoutDestroyingRTCAndFinalStopIsIdempotent() async throws {
        let capture = CameraCaptureControllingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let rtc = RtcManagingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)), cameraCapture: capture,
            microphoneCapture: MicrophoneCaptureControllingStub()
        )
        let media = MediaController(
            rtcManager: rtc, cameraController: camera, cameraVideoFrameListener: { _ in }, externalVideoFrameListener: { _ in },
            errorListener: { _ in }, interactionListener: { _, _ in }
        )
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
            cameraCapture: CameraCaptureControllingStub(devices: [
                CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
            ]),
            microphoneCapture: MicrophoneCaptureControllingStub()
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        _ = try await components.manager.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), camera: .systemDefault
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
        XCTAssertTrue(source.sink?.isRequestingFrames ?? false)
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
        try await waitUntil { !roomMessages(components.rtc, event: "start").isEmpty }
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
        XCTAssertTrue(sink.isRequestingFrames)
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
        try await waitUntil { await components.manager.currentState.connectionState == .idle }
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
        let source = ExternalSourceStub(videoFormat: RealtimeVideoFormat(width: 640, height: 500, fps: 30))
        let local = try await components.manager.createExternalVideoStream(source: source)
        let generation = Task {
            try await components.manager.startGeneration(localStream: local, context: RealtimeContext(prompt: "test"))
        }
        try await waitUntil { !self.roomMessages(components.rtc, event: "start").isEmpty }
        let event = try XCTUnwrap(roomMessages(components.rtc, event: "start").first)
        let params = try XCTUnwrap(event["params"] as? [String: Any])
        XCTAssertEqual(local.videoTrack?.videoFormat?.size, CGSize(width: 640, height: 500))
        XCTAssertEqual(params["size"] as? [Int], [1536, 1152])
        XCTAssertEqual(params["padding"] as? String, "contain")
        await components.manager.close()
        do { _ = try await generation.value; XCTFail("Expected close cancellation") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
    }

    func testManualQualityControlRetainsBaselineAndDisabledAdaptationStartsAtL1() async throws {
        let baseline = RealtimeVideoFormat(width: 1920, height: 1024, fps: 30)
        let components = makeComponents(
            mediaService: MediaServicingStub(resolvedSize: baseline.size),
            options: RealtimeConfiguration(model: .x2_1, isAdaptiveQualityEnabled: false)
        )
        let manager: any XmaxRealtimeManaging = components.manager
        let before = await manager.uplinkQualityLevel
        XCTAssertNil(before)
        do {
            try await manager.setUplinkQualityLevel(.l3)
            XCTFail("Manual quality requires an active generation")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
        let source = RealtimeExternalVideoSourceStub(videoFormat: baseline)
        let local = try await manager.createExternalVideoStream(source: source)
        let generation = Task {
            try await manager.startGeneration(localStream: local, context: RealtimeContext(prompt: "quality"))
        }
        try await waitUntil { !roomMessages(components.rtc, event: "start").isEmpty }
        components.rtc.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room", userID: "bot"))
        try await waitUntil {
            components.rtc.calls.contains { if case .setRemoteVideoFrameListener(_, enabled: true) = $0 { true } else { false } }
        }
        try components.rtc.emitRemoteVideoFrame(width: 4, height: 4)
        _ = try await generation.value
        let initialUp = await manager.uplinkQualityLevel
        let initialDown = await manager.downlinkQualityLevel
        XCTAssertEqual(initialUp, .l1)
        XCTAssertEqual(initialDown, .l1)
        try await manager.setUplinkQualityLevel(.l3)
        try await manager.setDownlinkQualityLevel(.l5)
        let appliedUp = await manager.uplinkQualityLevel
        let appliedDown = await manager.downlinkQualityLevel
        XCTAssertEqual(appliedUp, .l3)
        XCTAssertEqual(appliedDown, .l5)
        XCTAssertEqual(local.videoTrack?.videoFormat, baseline)
        XCTAssertEqual(components.rtc.encodingConfigurations.last?.width, 1440)
        XCTAssertEqual(components.rtc.encodingConfigurations.last?.height, 768)
        XCTAssertFalse(roomMessages(components.rtc, event: "change_target_size").isEmpty)
        await manager.disconnect()
        let disconnected = await manager.uplinkQualityLevel
        XCTAssertNil(disconnected)
        XCTAssertTrue(source.sink?.isRequestingFrames ?? false)
        await manager.close()
    }

    func testExternalPCMIsPublishedWithoutMicrophoneAndUnbindingStopsItsTrack() async throws {
        let components = makeComponents()
        let source = RealtimeExternalVideoSourceStub(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30), hasAudio: true
        )
        let local = try await components.manager.createExternalVideoStream(source: source)
        let sink = try XCTUnwrap(source.sink)
        sink.pushAudio(try AudioSampleBufferFactory.make())
        XCTAssertFalse(components.rtc.calls.contains { if case .pushExternalAudioFrame = $0 { true } else { false } })
        _ = try await components.manager.connect(localStream: local)
        XCTAssertTrue(components.rtc.calls.contains(.publishLocalAudio))
        sink.pushAudio(try AudioSampleBufferFactory.make(timestamp: CMTime(value: 10, timescale: 1000)))
        XCTAssertTrue(components.rtc.calls.contains { if case .pushExternalAudioFrame = $0 { true } else { false } })
        await components.manager.disconnect()
        try await components.manager.stopExternalVideoStream()
        XCTAssertEqual(components.rtc.calls.filter { $0 == .stopExternalAudioSource }.count, 1)
        XCTAssertEqual(source.stopCount, 1)
    }

    func testCameraFormatRequiresReadyDisconnectedCameraAndRetainsTrackAcrossUpdates() async throws {
        let rtc = RtcManagingStub()
        let device = CameraDevice(id: "usb", name: "USB", isDefault: true, position: .unspecified)
        let service = MediaService()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: service,
            cameraCapture: CameraCaptureControllingStub(devices: [device], automaticallyReady: true),
            microphoneCapture: MicrophoneCaptureControllingStub()
        )
        let components = makeComponents(rtc: rtc, camera: camera, mediaService: service)
        let manager: any XmaxRealtimeManaging = components.manager
        let initial = RealtimeModel.x2_1.defaultCameraVideoFormat
        let missing = await manager.currentCameraVideoFormat
        XCTAssertNil(missing)
        let local = try await manager.createLocalCameraStream(videoFormat: initial, camera: .systemDefault)
        let track = try XCTUnwrap(local.videoTrack)
        let next = RealtimeVideoFormat(width: 1080, height: 1920, fps: 24)
        do { try await manager.updateCameraFormat(next); XCTFail("Expected preview readiness requirement") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        try await waitUntil { await manager.currentState.connectionState == .ready }
        try await manager.updateCameraFormat(next)
        let applied = await manager.currentCameraVideoFormat
        let preset = await manager.currentCameraPreset
        XCTAssertEqual(applied, next)
        XCTAssertEqual(preset, .resolution1080x1920)
        XCTAssertTrue(camera.currentTrack === track)
        do {
            try await manager.updateCameraFormat(RealtimeVideoFormat(width: 1920, height: 1024, fps: 30))
            XCTFail("Expected unsupported camera dimensions")
        }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
        XCTAssertEqual(track.videoFormat, next)
        try await manager.updateCameraFormat(.resolution1408x1408)
        XCTAssertEqual(track.videoFormat, RealtimeVideoFormat(width: 1408, height: 1408, fps: 24))
        _ = try await manager.connect(localStream: local)
        let callsBefore = rtc.calls.count
        do { try await manager.updateCameraFormat(initial); XCTFail("Expected connected format rejection") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
        XCTAssertEqual(rtc.calls.count, callsBefore)
        await manager.disconnect()
        try await manager.updateCameraFormat(initial)
        XCTAssertEqual(track.videoFormat, initial)
        XCTAssertTrue(camera.currentTrack === track)
        await manager.close()
        let stopped = await manager.currentCameraVideoFormat
        XCTAssertNil(stopped)
    }

    func testExternalInputDoesNotExposeOrAcceptCameraFormatControls() async throws {
        let components = makeComponents()
        _ = try await components.manager.createExternalVideoStream(source: ExternalSourceStub())
        let format = await components.manager.currentCameraVideoFormat
        let preset = await components.manager.currentCameraPreset
        XCTAssertNil(format)
        XCTAssertNil(preset)
        do {
            try await components.manager.updateCameraFormat(.resolution1920x1080)
            XCTFail("Expected camera-only format control")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
        await components.manager.close()
    }

    func testCameraCreationForwardsCameraMirrorAndMicrophoneChoicesThroughPublicOverloads() async throws {
        for variant in 0..<7 {
            let rtc = RtcManagingStub()
            let permissions = PermissionManagingStub()
            let usb = CameraDevice(id: "usb", name: "USB", isDefault: false, position: .unspecified)
            let builtin = CameraDevice(id: "builtin", name: "Built-in", isDefault: true, position: .front)
            let capture = CameraCaptureControllingStub(devices: [usb, builtin], automaticallyReady: true)
            let microphone = MicrophoneCaptureControllingStub()
            let camera = CameraController(
                rtcManager: rtc, permissionManager: permissions, mediaService: MediaService(),
                cameraCapture: capture,
                microphoneCapture: microphone
            )
            let components = makeComponents(rtc: rtc, camera: camera)
            let manager: any XmaxRealtimeManaging = components.manager
            let format = RealtimeVideoFormat(width: 1920, height: 1080, fps: 30)
            switch variant {
            case 0:
                _ = try await manager.createLocalCameraStream(
                    microphone: .device(id: "usb-input"),
                    mirror: true
                )
            case 1:
                _ = try await manager.createLocalCameraStream(
                    videoFormat: format,
                    microphone: .device(id: "usb-input"),
                    mirror: true
                )
            case 2:
                _ = try await manager.createLocalCameraStream(
                    videoFormat: format,
                    camera: .device(id: "usb"),
                    microphone: .device(id: "usb-input"),
                    mirror: true
                )
            case 3:
                _ = try await manager.createLocalCameraStream(
                    videoFormat: format,
                    camera: .device(id: "usb"),
                    mirror: true
                )
            case 4:
                _ = try await manager.createLocalCameraStream(
                    preset: .resolution1920x1080,
                    microphone: .device(id: "usb-input"),
                    mirror: true
                )
            case 5:
                _ = try await manager.createLocalCameraStream(
                    videoFormat: format,
                    camera: .device(id: "usb"),
                    microphone: .device(id: "usb-input")
                )
            default:
                _ = try await manager.createLocalCameraStream(
                    videoFormat: format,
                    camera: .device(id: "usb"),
                    microphone: .systemDefault,
                    mirror: true
                )
            }
            let expectedCameraID = [0, 1, 4].contains(variant) ? builtin.id : usb.id
            XCTAssertEqual(capture.calls, [.start(expectedCameraID)])
            XCTAssertEqual(rtc.cameraMirrors, [variant != 5])
            XCTAssertTrue(microphone.calls.contains(.select([3, 6].contains(variant) ? nil : "usb-input")))
            XCTAssertEqual(permissions.microphoneRequestCount, variant == 3 ? 0 : 1)
            let microphoneEnabled = await manager.isMicrophoneEnabled
            XCTAssertEqual(microphoneEnabled, variant != 3)
            XCTAssertFalse(microphone.calls.contains(.start))
            XCTAssertFalse(rtc.calls.contains(.publishLocalAudio))
            await manager.close()
        }
    }

    func testInvalidInitialMicrophoneReleasesMediaWithoutStartingCameraOrAudio() async throws {
        let failure = XmaxError(code: .mediaError, message: "Microphone input is unavailable")
        let rtc = RtcManagingStub()
        let permissions = PermissionManagingStub()
        let capture = CameraCaptureControllingStub(devices: [
            CameraDevice(id: "camera", name: "Camera", isDefault: true, position: .front)
        ])
        let microphone = MicrophoneCaptureControllingStub(selectionError: failure)
        let camera = CameraController(
            rtcManager: rtc,
            permissionManager: permissions,
            mediaService: MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4)),
            cameraCapture: capture,
            microphoneCapture: microphone
        )
        let manager = makeComponents(rtc: rtc, camera: camera).manager
        for microphone: RealtimeMicrophone in [.device(id: "removed-input"), .systemDefault] {
            do {
                _ = try await manager.createLocalCameraStream(
                    microphone: microphone
                )
                XCTFail("Expected input selection to fail")
            } catch {
                XCTAssertEqual(error as? XmaxError, failure)
            }
        }
        XCTAssertNil(camera.currentTrack)
        XCTAssertTrue(capture.calls.isEmpty)
        XCTAssertEqual(permissions.cameraRequestCount, 0)
        XCTAssertEqual(permissions.microphoneRequestCount, 0)
        XCTAssertFalse(microphone.calls.contains(.start))
        XCTAssertEqual(rtc.calls.filter { $0 == .destroy }.count, 2)
        await manager.close()
    }

    func testPresetCreationSupportsEveryModelFormatAndKeepsLandscapeDefault() async throws {
        for model in RealtimeModel.allCases {
            let rtc = RtcManagingStub()
            let device = CameraDevice(id: "usb", name: "USB", isDefault: true, position: .unspecified)
            let capture = CameraCaptureControllingStub(devices: [device], automaticallyReady: true)
            let camera = CameraController(
                rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(model: model),
                cameraCapture: capture,
                microphoneCapture: MicrophoneCaptureControllingStub()
            )
            let components = makeComponents(rtc: rtc, camera: camera, options: RealtimeConfiguration(model: model))
            let manager: any XmaxRealtimeManaging = components.manager
            for preset in RealtimeCameraPreset.allCases {
                let expected = try XCTUnwrap(model.supportedVideoFormats.first { $0.size == preset.size })
                let local = try await manager.createLocalCameraStream(
                    preset: preset, camera: .device(id: "usb"), microphone: .systemDefault
                )
                XCTAssertEqual(local.videoTrack?.videoFormat, expected)
                XCTAssertEqual(local.videoTrack?.device, device)
                XCTAssertTrue(camera.useMicrophone)
                try await manager.stopLocalCameraStream()
            }
            let callsBefore = capture.calls.count
            do {
                _ = try await manager.createLocalCameraStream(
                    videoFormat: RealtimeVideoFormat(width: 1920, height: 1024, fps: 30)
                )
                XCTFail("Expected unsupported camera dimensions")
            } catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
            XCTAssertFalse(capture.calls.dropFirst(callsBefore).contains {
                if case .start = $0 { return true }
                return false
            }, "Unsupported dimensions must not start capture")
            XCTAssertNil(camera.currentTrack)
            let idle = await manager.currentState
            XCTAssertEqual(idle.connectionState, .idle)
            let local = try await manager.createLocalCameraStream()
            XCTAssertEqual(local.videoTrack?.videoFormat, RealtimeVideoFormat(width: 1920, height: 1080, fps: 30))
            XCTAssertEqual(local.videoTrack?.device, device)
            await manager.close()
        }
    }

    func testStateCallbacksCanChainReadyConnectionGenerationAndConfiguration() async throws {
        let components = makeComponents()
        let manager = components.manager
        let source = ExternalSourceStub()
        var connection: Task<RealtimeMediaStream, any Error>?
        var generation: Task<Void, any Error>?
        var configuration: Task<Void, any Error>?
        var states: [RealtimeConnectionState] = []
        await manager.setStateListener { snapshot in
            states.append(snapshot.connectionState)
            switch snapshot.connectionState {
            case .ready where connection == nil:
                connection = Task {
                    let current = await components.media.currentTrack
                    let local = RealtimeMediaStream(id: StreamID.local.rawValue, videoTrack: try XCTUnwrap(current))
                    return try await manager.connect(localStream: local)
                }
            case .connected where generation == nil:
                generation = Task { try await manager.startGeneration(context: RealtimeContext(prompt: "callback chain")) }
            case .generating where configuration == nil:
                configuration = Task { try await manager.setFrameInterpolationEnabled(false) }
            default: break
            }
        }
        _ = try await manager.createExternalVideoStream(source: source)
        try await waitUntil { !self.roomMessages(components.rtc, event: "start").isEmpty || (generation?.isCancelled ?? false) }
        components.rtc.emitRemoteVideoAvailable(stream: RemoteStream(roomID: "room", userID: "bot"))
        try await waitUntil {
            components.rtc.calls.contains(.setRemoteVideoFrameListener(RemoteStream(roomID: "room", userID: "bot"), enabled: true))
        }
        try components.rtc.emitRemoteVideoFrame(width: 4, height: 4)
        _ = try await XCTUnwrap(connection).value
        try await XCTUnwrap(generation).value
        try await XCTUnwrap(configuration).value
        XCTAssertEqual(states, [.idle, .preparing, .ready, .connecting, .connected, .generating])
        XCTAssertEqual(components.rtc.calls.filter { if case .joinRoom = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(source.stops, 0)
        await manager.setStateListener(nil)
        await manager.close()
    }

    func testExternalStopCallbackCanImmediatelyCreateAnotherInput() async throws {
        let components = makeComponents()
        let manager = components.manager
        let first = ExternalSourceStub()
        let next = ExternalSourceStub()
        _ = try await manager.createExternalVideoStream(source: first)
        var replacement: Task<RealtimeMediaStream, any Error>?
        await manager.setStateListener { state in
            if state.connectionState == .idle, replacement == nil {
                replacement = Task { try await manager.createExternalVideoStream(source: next) }
            }
        }
        try await manager.stopExternalVideoStream()
        _ = try await XCTUnwrap(replacement).value
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(next.stops, 0)
        let ready = await manager.currentState
        XCTAssertEqual(ready.connectionState, .ready)
        await manager.setStateListener(nil)
        await manager.close()
    }

    func testCameraConvenienceAndStopCallbackRetainDeviceSelectionAndMicrophoneOptions() async throws {
        let rtc = RtcManagingStub()
        let device = CameraDevice(id: "usb", name: "USB", isDefault: true, position: .unspecified)
        let capture = CameraCaptureControllingStub(devices: [device], automaticallyReady: true)
        let microphone = MicrophoneCaptureControllingStub()
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            cameraCapture: capture,
            microphoneCapture: microphone
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        let manager: any XmaxRealtimeManaging = components.manager
        let format = RealtimeVideoFormat(width: 1920, height: 1080, fps: 30)
        let first = try await manager.createLocalCameraStream(
            videoFormat: format,
            microphone: .device(id: "usb-input")
        )
        XCTAssertEqual(first.videoTrack?.device, device)
        XCTAssertEqual(first.videoTrack?.videoFormat, format)
        XCTAssertTrue(camera.useMicrophone)
        XCTAssertFalse(microphone.calls.contains(.start), "Microphone capture starts on connection")
        var replacement: Task<RealtimeMediaStream, any Error>?
        await manager.setStateListener { state in
            if state.connectionState == .idle, replacement == nil {
                replacement = Task { try await manager.createLocalCameraStream(videoFormat: format, camera: .device(id: "usb")) }
            }
        }
        try await manager.stopLocalCameraStream()
        let second = try await XCTUnwrap(replacement).value
        XCTAssertFalse(first.videoTrack === second.videoTrack)
        XCTAssertEqual(second.videoTrack?.device, device)
        XCTAssertFalse(camera.useMicrophone)
        XCTAssertEqual(microphone.calls, [
            .select("usb-input"),
            .select(nil)
        ])
        await manager.setStateListener(nil)
        await manager.close()
    }

    func testCameraPreparationDoesNotPublishGenerationTimingBeforeGenerationBegins() async throws {
        let rtc = RtcManagingStub()
        let device = CameraDevice(id: "usb", name: "USB", isDefault: true, position: .unspecified)
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            cameraCapture: CameraCaptureControllingStub(devices: [device], automaticallyReady: true),
            microphoneCapture: MicrophoneCaptureControllingStub()
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        let manager = components.manager
        var snapshots: [RealtimeLaunchTiming] = []
        let initial = expectation(description: "Initial empty timing snapshot")
        await manager.setLaunchTimingListener { snapshot in
            snapshots.append(snapshot)
            if snapshots.count == 1 { initial.fulfill() }
        }
        await fulfillment(of: [initial], timeout: 2)
        let local = try await manager.createLocalCameraStream()
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: XCTUnwrap(local.videoTrack))?.attach(to: view, contentMode: .fit)
        try await waitUntil { await manager.currentState.connectionState == .ready }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(snapshots, [RealtimeLaunchTiming()], "Camera preparation must not emit generation measurements")

        let generation = Task {
            try await manager.startGeneration(localStream: local, context: RealtimeContext(prompt: "timed generation"))
        }
        try await waitUntil { !self.roomMessages(rtc, event: "start").isEmpty }
        let remote = RemoteStream(roomID: "room", userID: "bot")
        rtc.emitRemoteVideoAvailable(stream: remote)
        try await waitUntil { rtc.calls.contains(.setRemoteVideoFrameListener(remote, enabled: true)) }
        try rtc.emitRemoteVideoFrame(width: 4, height: 4)
        _ = try await generation.value
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let finished = try XCTUnwrap(snapshots.last)
        XCTAssertNotNil(finished.sessionMs)
        XCTAssertNotNil(finished.rtcJoinMs)
        XCTAssertNotNil(finished.publishMs)
        XCTAssertNotNil(finished.firstFrameMs)
        XCTAssertNotNil(finished.totalMs)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(finished.totalMs), try XCTUnwrap(finished.firstFrameMs))
        await manager.close()
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
        capture: (camera: CameraCaptureControllingStub, microphone: MicrophoneCaptureControllingStub)? = nil,
        mediaService: (any MediaServicing)? = nil,
        microphoneDevices: @escaping @Sendable () -> [MicrophoneDevice] = { [] },
        options: RealtimeConfiguration = RealtimeConfiguration(model: .x2_1)
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
        let cameraVideoFrameListener: MediaVideoFrameListener = { frame in
            stream.enqueueLocalCameraVideoFrame(frame, errorListener: { errors.forward($0, target: .all) })
        }
        let testCamera = capture.map {
            CameraController(
                rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: service,
                cameraCapture: $0.camera,
                microphoneCapture: $0.microphone,
                videoFrameListener: cameraVideoFrameListener,
                audioFrameListener: { try stream.pushLocalAudioFrame($0) }
            )
        }
        let media = MediaController(
            rtcManager: rtc, mediaService: service, cameraController: camera ?? testCamera,
            cameraVideoFrameListener: cameraVideoFrameListener,
            externalVideoFrameListener: { try stream.pushLocalVideoFrame($0) },
            audioFrameListener: { try stream.pushLocalAudioFrame($0) },
            errorListener: { errors.forward($0, target: .all) },
            microphoneDevices: microphoneDevices,
            interactionListener: { try await stream.sendTracks(taskID: $0, points: $1) }
        )
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
            options: options,
            components: XmaxRealtimeFactory.assemble(
                connectionManager: connection, generationManager: generation, errorManager: errors,
                mediaController: media, renderController: render, streamController: stream,
                mediaService: service, timing: timing
            )
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

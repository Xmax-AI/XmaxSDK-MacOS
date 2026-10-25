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

    func testManualQualityControlRetainsBaselineAndDisabledAdaptationStartsAtL1() async throws {
        let baseline = RealtimeVideoFormat(width: 1920, height: 1024, fps: 30)
        let components = makeComponents(
            mediaService: MediaServicingStub(resolvedSize: baseline.size),
            options: RealtimeConfiguration(model: .x2_1_1_preview_cn, isAdaptiveQualityEnabled: false)
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
        XCTAssertFalse(components.rtc.calls.contains(.startAudioCapture))
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
            captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { [device] })
        )
        let components = makeComponents(rtc: rtc, camera: camera, mediaService: service)
        let manager: any XmaxRealtimeManaging = components.manager
        let initial = RealtimeModel.x2_1_1_preview_cn.defaultCameraVideoFormat
        let missing = await manager.currentCameraVideoFormat
        XCTAssertNil(missing)
        let local = try await manager.createLocalCameraStream(videoFormat: initial, deviceID: nil)
        let track = try XCTUnwrap(local.videoTrack)
        let next = RealtimeVideoFormat(width: 1024, height: 1920, fps: 24)
        do { try await manager.updateCameraFormat(next); XCTFail("Expected preview readiness requirement") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        try await waitUntil { await manager.currentState.connectionState == .ready }
        try await manager.updateCameraFormat(next)
        let applied = await manager.currentCameraVideoFormat
        let preset = await manager.currentCameraPreset
        XCTAssertEqual(applied, next)
        XCTAssertNil(preset, "The model dimensions do not match the shared resolution presets")
        XCTAssertTrue(camera.currentTrack === track)
        do { try await manager.updateCameraFormat(.resolution1920x1080); XCTFail("Expected unsupported preset") }
        catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
        XCTAssertEqual(track.videoFormat, next)
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

    func testCameraCreationForwardsMirrorThroughPublicConvenienceOverloads() async throws {
        for variant in 0..<4 {
            let rtc = RtcManagingStub()
            let device = CameraDevice(id: "usb", name: "USB", isDefault: true, position: .unspecified)
            let camera = CameraController(
                rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
                captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { [device] })
            )
            let components = makeComponents(rtc: rtc, camera: camera)
            let manager: any XmaxRealtimeManaging = components.manager
            let format = RealtimeVideoFormat(width: 1920, height: 1024, fps: 30)
            switch variant {
            case 0: _ = try await manager.createLocalCameraStream(mirror: true)
            case 1: _ = try await manager.createLocalCameraStream(videoFormat: format, mirror: true)
            case 2: _ = try await manager.createLocalCameraStream(videoFormat: format, deviceID: "usb", mirror: true)
            default: _ = try await manager.createLocalCameraStream(videoFormat: format, deviceID: "usb", mirror: true, useMicrophone: true)
            }
            XCTAssertEqual(rtc.cameraMirrors, [true])
            await manager.close()
        }
    }

    func testPresetCreationRejectsUnsupportedSizesBeforeCaptureAndKeepsLandscapeDefault() async throws {
        for model in RealtimeModel.allCases {
            let rtc = RtcManagingStub()
            let device = CameraDevice(id: "usb", name: "USB", isDefault: true, position: .unspecified)
            let camera = CameraController(
                rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(model: model),
                captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { [device] })
            )
            let components = makeComponents(rtc: rtc, camera: camera, options: RealtimeConfiguration(model: model))
            let manager: any XmaxRealtimeManaging = components.manager
            for preset in RealtimeCameraPreset.allCases {
                XCTAssertFalse(model.supportedVideoFormats.contains { $0.size == preset.size })
                do {
                    _ = try await manager.createLocalCameraStream(preset: preset, deviceID: "usb", useMicrophone: true)
                    XCTFail("Expected preset/model compatibility validation")
                } catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
            }
            XCTAssertTrue(rtc.calls.isEmpty, "Unsupported presets must not initialize RTC or start capture")
            XCTAssertNil(camera.currentTrack)
            let idle = await manager.currentState
            XCTAssertEqual(idle.connectionState, .idle)
            let local = try await manager.createLocalCameraStream()
            XCTAssertEqual(local.videoTrack?.videoFormat, RealtimeVideoFormat(width: 1920, height: 1024, fps: 30))
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
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { [device] })
        )
        let components = makeComponents(rtc: rtc, camera: camera)
        let manager: any XmaxRealtimeManaging = components.manager
        let format = RealtimeVideoFormat(width: 1920, height: 1024, fps: 30)
        let first = try await manager.createLocalCameraStream(videoFormat: format, useMicrophone: true)
        XCTAssertEqual(first.videoTrack?.device, device)
        XCTAssertEqual(first.videoTrack?.videoFormat, format)
        XCTAssertTrue(camera.useMicrophone)
        XCTAssertFalse(rtc.calls.contains(.startAudioCapture), "Microphone capture starts on connection")
        var replacement: Task<RealtimeMediaStream, any Error>?
        await manager.setStateListener { state in
            if state.connectionState == .idle, replacement == nil {
                replacement = Task { try await manager.createLocalCameraStream(videoFormat: format, deviceID: "usb") }
            }
        }
        try await manager.stopLocalCameraStream()
        let second = try await XCTUnwrap(replacement).value
        XCTAssertFalse(first.videoTrack === second.videoTrack)
        XCTAssertEqual(second.videoTrack?.device, device)
        XCTAssertFalse(camera.useMicrophone)
        await manager.setStateListener(nil)
        await manager.close()
    }

    func testCameraPreparationDoesNotPublishGenerationTimingBeforeGenerationBegins() async throws {
        let rtc = RtcManagingStub()
        let device = CameraDevice(id: "usb", name: "USB", isDefault: true, position: .unspecified)
        let camera = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { [device] })
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
        mediaService: (any MediaServicing)? = nil,
        options: RealtimeConfiguration = RealtimeConfiguration(model: .x2_1_1_preview_cn)
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
                audioFrameListener: { try stream.pushLocalAudioFrame($0) },
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
            options: options,
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

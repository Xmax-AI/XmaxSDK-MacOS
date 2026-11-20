//
//  CameraControllerTests.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import AVFoundation
import XCTest
@testable import XmaxSDK

final class CameraControllerTests: XCTestCase, @unchecked Sendable {

    private let builtIn = CameraDevice(id: "builtin", name: "Built-in", isDefault: true, position: .front)
    private let external = CameraDevice(id: "usb", name: "USB", isDefault: false, position: .back)
    private let format = RealtimeVideoFormat(width: 1920, height: 1080, fps: 30)

    func testDefaultCameraUsesSystemDefaultInsteadOfFirstDevice() async throws {
        let capture = CameraCaptureControllingStub(devices: [external, builtIn])
        let controller = makeController(capture)
        let stream = try await controller.createLocalCameraStream(videoFormat: format, camera: .systemDefault)
        XCTAssertEqual(stream.videoTrack?.device, builtIn)
        XCTAssertEqual(capture.calls, [.start("builtin")])
        await controller.stopLocalCameraStream()
    }

    func testExplicitUnavailableDeviceDoesNotFallBackToDefault() async {
        let capture = CameraCaptureControllingStub(devices: [builtIn])
        let controller = makeController(capture)
        do {
            _ = try await controller.createLocalCameraStream(videoFormat: format, camera: .device(id: "removed"))
            XCTFail("Expected unavailable device to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        XCTAssertTrue(capture.calls.isEmpty)
        XCTAssertNil(controller.currentTrack)
    }

    @MainActor
    func testExplicitMirrorIsAppliedOnceBeforePreviewAndEncodingForEveryCameraPosition() async throws {
        for position in [CameraPosition.front, .back, .unspecified] {
            for mirror in [false, true] {
                let device = CameraDevice(id: "camera", name: "Camera", isDefault: true, position: position)
                let capture = CameraCaptureControllingStub(devices: [device])
                let rtc = RtcManagingStub()
                let controller = makeController(capture, rtc: rtc)
                let stream = try await controller.createLocalCameraStream(videoFormat: format, camera: .systemDefault, mirror: mirror)
                let track = try XCTUnwrap(stream.videoTrack)
                let view = XmaxRealtimeVideoView()
                try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
                let layer = try XCTUnwrap(view.layer?.sublayers?.first { $0 is AVSampleBufferDisplayLayer })
                XCTAssertEqual(layer.affineTransform().a, 1)
                XCTAssertEqual(capture.mirrors, [mirror])
                XCTAssertEqual(rtc.calls, [.useExternalVideoSource])
                await controller.stopLocalCameraStream()
            }
        }
    }

    @MainActor
    func testCameraSwitchKeepsTrackIdentityAndUpdatesDevice() async throws {
        let capture = CameraCaptureControllingStub(devices: [builtIn, external])
        let rtc = RtcManagingStub()
        let controller = makeController(capture, rtc: rtc)
        let local = try await controller.createLocalCameraStream(videoFormat: format, camera: .device(id: "builtin"), mirror: true)
        let track = try XCTUnwrap(local.videoTrack)
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        let canvas = try XCTUnwrap(view.layer?.sublayers?.first { $0 is AVSampleBufferDisplayLayer })
        let switched = try await controller.switchCamera(to: "usb")
        XCTAssertTrue(local.videoTrack === switched.videoTrack)
        XCTAssertEqual(switched.videoTrack?.device, external)
        XCTAssertTrue(view.layer?.sublayers?.contains { $0 === canvas } ?? false)
        XCTAssertEqual(capture.mirrors, [true, true])
        XCTAssertEqual(capture.calls, [.start("builtin"), .switchCamera("usb")])
        XCTAssertEqual(rtc.calls, [.useExternalVideoSource])
        await controller.stopLocalCameraStream()
    }

    func testFailedSwitchPreservesCurrentDevice() async throws {
        let capture = CameraCaptureControllingStub(
            devices: [builtIn, external], startError: nil,
            switchError: XmaxError(code: .mediaError, message: "Device unavailable")
        )
        let controller = makeController(capture)
        _ = try await controller.createLocalCameraStream(videoFormat: format, camera: .systemDefault)
        do {
            _ = try await controller.switchCamera(to: "usb")
            XCTFail("Expected device switch failure")
        } catch {
            XCTAssertEqual(controller.currentTrack?.device, builtIn)
        }
        await controller.stopLocalCameraStream()
    }

    func testCaptureFailureReleasesTrackAndRenderBinding() async {
        let capture = CameraCaptureControllingStub(
            devices: [builtIn], startError: XmaxError(code: .mediaError, message: "Capture failed")
        )
        let controller = makeController(capture)
        do {
            _ = try await controller.createLocalCameraStream(videoFormat: format, camera: .systemDefault)
            XCTFail("Expected capture failure")
        } catch {
            XCTAssertNil(controller.currentTrack)
            XCTAssertEqual(capture.calls, [.start("builtin"), .stop])
        }
    }

    @MainActor
    func testReadyRequiresNativeCaptureAndPreviewBindingAndBecomesInvalidAfterStop() async throws {
        let capture = CameraCaptureControllingStub(devices: [builtIn])
        let controller = makeController(capture)
        let stream = try await controller.createLocalCameraStream(videoFormat: format, camera: .systemDefault)
        let track = try XCTUnwrap(stream.videoTrack)
        let ready = expectation(description: "Preview ready")
        var receivedReady = false
        var isCurrent: (@Sendable () -> Bool)?
        controller.setPreviewReadyHandler { validity in
            receivedReady = true
            isCurrent = validity
            ready.fulfill()
        }
        let oldReadyListener = try XCTUnwrap(capture.currentPreviewReadyListener)
        oldReadyListener()
        await Task.yield()
        XCTAssertFalse(receivedReady)
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(isCurrent?(), true)
        await controller.stopLocalCameraStream()
        XCTAssertEqual(isCurrent?(), false)
        XCTAssertNil(VideoRenderRegistry.binding(for: track))
        oldReadyListener()
        XCTAssertNil(controller.currentTrack)
    }

    @MainActor
    func testFormatUpdatePreservesTrackDeviceAndPreviewCanvas() async throws {
        let capture = CameraCaptureControllingStub(devices: [builtIn])
        let controller = makeController(capture)
        let local = try await controller.createLocalCameraStream(videoFormat: format, camera: .systemDefault)
        let track = try XCTUnwrap(local.videoTrack)
        let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: track))
        let view = XmaxRealtimeVideoView()
        try binding.attach(to: view, contentMode: .fit)
        let canvas = try XCTUnwrap(view.layer?.sublayers?.first { $0 is AVSampleBufferDisplayLayer })
        let updated = RealtimeVideoFormat(width: 1080, height: 1920, fps: 24, maximumBitrate: 1200)
        try await controller.updateVideoFormat(updated)
        XCTAssertTrue(controller.currentTrack === track)
        XCTAssertEqual(track.videoFormat, updated)
        XCTAssertEqual(track.device, builtIn)
        XCTAssertTrue(view.layer?.sublayers?.contains { $0 === canvas } ?? false)
        XCTAssertNotNil(VideoRenderRegistry.binding(for: track))
        XCTAssertEqual(capture.calls, [.start("builtin"), .updateFormat(
            try VideoFormat(width: 1080, height: 1920, pixelFormat: .nv12), 24
        )])
        await controller.stopLocalCameraStream()
    }

    func testUnsupportedFormatDoesNotChangeCaptureOrTrack() async throws {
        let capture = CameraCaptureControllingStub(devices: [builtIn])
        let controller = makeController(capture)
        let local = try await controller.createLocalCameraStream(videoFormat: format, camera: .systemDefault)
        do {
            try await controller.updateVideoFormat(RealtimeVideoFormat(width: 1920, height: 1024, fps: 30))
            XCTFail("Expected unsupported model dimensions")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
        XCTAssertEqual(local.videoTrack?.videoFormat, format)
        XCTAssertEqual(capture.calls, [.start("builtin")])
        await controller.stopLocalCameraStream()
    }

    func testFailedFormatUpdateRetainsPreviousFormatAndCanRetry() async throws {
        let capture = CameraCaptureControllingStub(devices: [builtIn])
        capture.updateError = XmaxError(code: .mediaError, message: "Reconfiguration failed")
        let controller = makeController(capture)
        let local = try await controller.createLocalCameraStream(videoFormat: format, camera: .systemDefault)
        let updated = RealtimeVideoFormat(width: 1080, height: 1920, fps: 24)
        do {
            try await controller.updateVideoFormat(updated)
            XCTFail("Expected capture failure")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .mediaError) }
        XCTAssertEqual(local.videoTrack?.videoFormat, format)
        XCTAssertTrue(controller.currentTrack === local.videoTrack)
        capture.updateError = nil
        try await controller.updateVideoFormat(updated)
        XCTAssertEqual(local.videoTrack?.videoFormat, updated)
        await controller.stopLocalCameraStream()
    }

    func testStoppedCameraCannotCommitLateFormatUpdate() async throws {
        let gate = CameraFormatGate()
        let capture = CameraCaptureControllingStub(devices: [builtIn])
        capture.updateHandler = { await gate.wait() }
        let controller = makeController(capture)
        let local = try await controller.createLocalCameraStream(videoFormat: format, camera: .systemDefault)
        let update = Task { try await controller.updateVideoFormat(
            RealtimeVideoFormat(width: 1080, height: 1920, fps: 24)
        ) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await gate.isWaiting) {
            guard ContinuousClock.now < deadline else { XCTFail("Update did not start"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        await controller.stopLocalCameraStream()
        await gate.release()
        do { try await update.value; XCTFail("Expected stale update cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(controller.currentTrack)
        XCTAssertEqual(local.videoTrack?.videoFormat, format)
    }

    func testPreferredCaptureFrameRateFallsBackToTheSupportedRange() throws {
        let minimum = CMTime(value: 1, timescale: 30)
        let maximum = CMTime(value: 1, timescale: 15)
        for (requested, expected): (Double, Double) in [(60, 30), (24, 24), (10, 15), (29.97, 29.97)] {
            let duration = try XCTUnwrap(CameraCaptureController.captureFrameDuration(
                frameRate: requested, minimum: minimum, maximum: maximum
            ))
            XCTAssertEqual(1 / duration.seconds, expected, accuracy: 0.0001)
        }
        for invalid in [Double.nan, .infinity, 0, -1] {
            XCTAssertNil(CameraCaptureController.captureFrameDuration(
                frameRate: invalid, minimum: minimum, maximum: maximum
            ))
        }
    }

    func testDefaultCameraPrefersFrontAndRecomputesAutomaticMirrorAfterSwitch() async throws {
        let front = CameraDevice(id: "front", name: "Front", isDefault: false, position: .front)
        let rear = CameraDevice(id: "rear", name: "Rear", isDefault: true, position: .back)
        let capture = CameraCaptureControllingStub(devices: [rear, front])
        let controller = makeController(capture)
        let local = try await controller.createLocalCameraStream(videoFormat: format)
        XCTAssertEqual(local.videoTrack?.device, front)
        _ = try await controller.switchCamera(to: rear.id)
        XCTAssertEqual(capture.mirrors, [true, false])
        await controller.stopLocalCameraStream()
    }

    func testUnknownFacingMirrorsOnlyTheDefaultDeviceUnlessPositionIsRequested() async throws {
        let defaultDevice = CameraDevice(id: "default", name: "Default", isDefault: true, position: .unspecified)
        let other = CameraDevice(id: "other", name: "Other", isDefault: false, position: .unspecified)
        for (camera, expected): (RealtimeCamera, Bool) in [
            (.device(id: "default"), true), (.device(id: "other"), false),
            (.position(.front), true), (.position(.back), false)
        ] {
            let capture = CameraCaptureControllingStub(devices: [other, defaultDevice])
            let controller = makeController(capture)
            _ = try await controller.createLocalCameraStream(videoFormat: format, camera: camera)
            XCTAssertEqual(capture.mirrors, [expected])
            await controller.stopLocalCameraStream()
        }
    }

    func testInvalidCapturePreferencesAndWarmupDoNotRequestPermissionsOrStartCamera() async {
        let invalid: [(CameraCaptureFormat?, Double)] = [
            (.init(width: 0, height: 1080), 0), (.init(width: 1920, height: -1), 0),
            (.init(width: 1920, height: 1080, fps: 0), 0),
            (.init(width: 1920, height: 1080, fps: .nan), 0),
            (.init(width: 1920, height: 1080, fps: .infinity), 0),
            (nil, -1), (nil, .nan), (nil, .infinity)
        ]
        for (captureFormat, warmupMs) in invalid {
            let permissions = PermissionManagingStub()
            let capture = CameraCaptureControllingStub(devices: [builtIn])
            let controller = CameraController(
                rtcManager: RtcManagingStub(), permissionManager: permissions, mediaService: MediaService(),
                cameraCapture: capture, microphoneCapture: MicrophoneCaptureControllingStub()
            )
            do {
                _ = try await controller.createLocalCameraStream(
                    videoFormat: format, captureFormat: captureFormat, warmupMs: warmupMs
                )
                XCTFail("Expected invalid camera options")
            } catch {
                XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
            }
            XCTAssertEqual(permissions.cameraRequestCount, 0)
            XCTAssertTrue(capture.calls.isEmpty)
        }
    }

    func testWarmupWaitsWhenRequestedAndCancellationEndsItPromptly() async throws {
        let capture = CameraCaptureControllingStub(devices: [builtIn])
        let controller = makeController(capture)
        _ = try await controller.createLocalCameraStream(videoFormat: format, warmupMs: 30)
        let started = ContinuousClock.now
        try await controller.waitForCameraWarmup()
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(25))
        await controller.stopLocalCameraStream()
        _ = try await controller.createLocalCameraStream(videoFormat: format, warmupMs: 3_600_000)
        let wait = Task { try await controller.waitForCameraWarmup() }
        wait.cancel()
        do {
            try await wait.value
            XCTFail("Expected warmup cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await controller.stopLocalCameraStream()
        _ = try await controller.createLocalCameraStream(videoFormat: format)
        try await controller.waitForCameraWarmup()
        await controller.stopLocalCameraStream()
    }

    private func makeController(
        _ capture: CameraCaptureControllingStub,
        rtc: RtcManagingStub = RtcManagingStub()
    ) -> CameraController {
        CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaService(),
            cameraCapture: capture,
            microphoneCapture: MicrophoneCaptureControllingStub()
        )
    }
}

private actor CameraFormatGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

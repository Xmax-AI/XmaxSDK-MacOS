//
//  CameraControllerTests.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
@preconcurrency import AVFoundation
import XCTest
@testable import XmaxSDK

final class CameraControllerTests: XCTestCase, @unchecked Sendable {

    private let builtIn = CameraDevice(id: "builtin", name: "Built-in", isDefault: true, position: .front)
    private let external = CameraDevice(id: "usb", name: "USB", isDefault: false, position: .back)
    private let format = RealtimeVideoFormat(width: 1920, height: 1024, fps: 30)

    func testDefaultCameraUsesSystemDefaultInsteadOfFirstDevice() async throws {
        let capture = CameraCaptureManagingStub(devices: [external, builtIn])
        let controller = makeController(capture)
        let stream = try await controller.createLocalCameraStream(videoFormat: format, deviceID: nil)
        XCTAssertEqual(stream.videoTrack?.device, builtIn)
        XCTAssertEqual(capture.calls, [.start("builtin")])
        await controller.stopLocalCameraStream()
    }

    func testExplicitUnavailableDeviceDoesNotFallBackToDefault() async {
        let capture = CameraCaptureManagingStub(devices: [builtIn])
        let controller = makeController(capture)
        do {
            _ = try await controller.createLocalCameraStream(videoFormat: format, deviceID: "removed")
            XCTFail("Expected unavailable device to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        XCTAssertTrue(capture.calls.isEmpty)
        XCTAssertNil(controller.currentTrack)
    }

    @MainActor
    func testExplicitMirrorControlsPreviewAndEncodingForEveryCameraPosition() async throws {
        for position in [CameraPosition.front, .back, .unspecified] {
            for mirror in [false, true] {
                let device = CameraDevice(id: "camera", name: "Camera", isDefault: true, position: position)
                let capture = CameraCaptureManagingStub(devices: [device])
                let rtc = RtcManagingStub()
                let controller = makeController(capture, rtc: rtc)
                let stream = try await controller.createLocalCameraStream(videoFormat: format, deviceID: nil, mirror: mirror)
                let track = try XCTUnwrap(stream.videoTrack)
                let view = XmaxVideoView()
                try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
                let layer = try XCTUnwrap(view.layer?.sublayers?.first { $0 is AVSampleBufferDisplayLayer })
                XCTAssertEqual(layer.affineTransform().a, mirror ? -1 : 1)
                XCTAssertEqual(rtc.cameraMirrors, [mirror])
                XCTAssertEqual(rtc.calls, [.useExternalVideoSource])
                await controller.stopLocalCameraStream()
            }
        }
    }

    @MainActor
    func testCameraSwitchKeepsTrackIdentityAndUpdatesDevice() async throws {
        let capture = CameraCaptureManagingStub(devices: [builtIn, external])
        let rtc = RtcManagingStub()
        let controller = makeController(capture, rtc: rtc)
        let local = try await controller.createLocalCameraStream(videoFormat: format, deviceID: "builtin", mirror: true)
        let track = try XCTUnwrap(local.videoTrack)
        let view = XmaxVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        let layer = try XCTUnwrap(view.layer?.sublayers?.first { $0 is AVSampleBufferDisplayLayer })
        XCTAssertEqual(layer.affineTransform().a, -1)
        let switched = try await controller.switchCamera(to: "usb")
        XCTAssertTrue(local.videoTrack === switched.videoTrack)
        XCTAssertEqual(switched.videoTrack?.device, external)
        XCTAssertEqual(layer.affineTransform().a, -1)
        XCTAssertEqual(rtc.cameraMirrors, [true])
        XCTAssertEqual(capture.calls, [.start("builtin"), .switchCamera("usb")])
        XCTAssertEqual(rtc.calls, [.useExternalVideoSource])
        await controller.stopLocalCameraStream()
    }

    func testFailedSwitchPreservesCurrentDevice() async throws {
        let capture = CameraCaptureManagingStub(
            devices: [builtIn, external], startError: nil,
            switchError: XmaxError(code: .mediaError, message: "Device unavailable")
        )
        let controller = makeController(capture)
        _ = try await controller.createLocalCameraStream(videoFormat: format, deviceID: nil)
        do {
            _ = try await controller.switchCamera(to: "usb")
            XCTFail("Expected device switch failure")
        } catch {
            XCTAssertEqual(controller.currentTrack?.device, builtIn)
        }
        await controller.stopLocalCameraStream()
    }

    func testCaptureFailureReleasesTrackAndRenderBinding() async {
        let capture = CameraCaptureManagingStub(
            devices: [builtIn], startError: XmaxError(code: .mediaError, message: "Capture failed")
        )
        let controller = makeController(capture)
        do {
            _ = try await controller.createLocalCameraStream(videoFormat: format, deviceID: nil)
            XCTFail("Expected capture failure")
        } catch {
            XCTAssertNil(controller.currentTrack)
            XCTAssertEqual(capture.calls, [.start("builtin"), .stop])
        }
    }

    @MainActor
    func testReadyRequiresCapturedFrameAndPreviewBindingAndBecomesInvalidAfterStop() async throws {
        let capture = CameraCaptureManagingStub(devices: [builtIn])
        let controller = makeController(capture)
        let stream = try await controller.createLocalCameraStream(videoFormat: format, deviceID: nil)
        let track = try XCTUnwrap(stream.videoTrack)
        let ready = expectation(description: "Preview ready")
        var receivedReady = false
        var isCurrent: (@Sendable () -> Bool)?
        controller.setPreviewReadyHandler { validity in
            receivedReady = true
            isCurrent = validity
            ready.fulfill()
        }
        let frame = try VideoFrame(
            format: VideoFormat(width: 4, height: 4, pixelFormat: .nv12), timestampUs: 1,
            planes: [
                VideoFramePlane(data: Data(repeating: 16, count: 16), stride: 4),
                VideoFramePlane(data: Data(repeating: 128, count: 8), stride: 4)
            ]
        )
        let oldFrameListener = capture.currentFrameListener
        try oldFrameListener?(frame)
        await Task.yield()
        XCTAssertFalse(receivedReady)
        let view = XmaxVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(isCurrent?(), true)
        await controller.stopLocalCameraStream()
        XCTAssertEqual(isCurrent?(), false)
        XCTAssertNil(VideoRenderRegistry.binding(for: track))
        try oldFrameListener?(frame)
        XCTAssertNil(controller.currentTrack)
    }

    @MainActor
    func testFormatUpdatePreservesTrackDeviceAndPreviewLayer() async throws {
        let capture = CameraCaptureManagingStub(devices: [builtIn])
        let controller = makeController(capture)
        let local = try await controller.createLocalCameraStream(videoFormat: format, deviceID: nil)
        let track = try XCTUnwrap(local.videoTrack)
        let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: track))
        let view = XmaxVideoView()
        try binding.attach(to: view, contentMode: .fit)
        let layer = try XCTUnwrap(view.layer?.sublayers?.first { $0 is AVSampleBufferDisplayLayer })
        let updated = RealtimeVideoFormat(width: 1024, height: 1920, fps: 24, maximumBitrate: 1200)
        try await controller.updateVideoFormat(updated)
        XCTAssertTrue(controller.currentTrack === track)
        XCTAssertEqual(track.videoFormat, updated)
        XCTAssertEqual(track.device, builtIn)
        XCTAssertTrue(view.layer?.sublayers?.contains { $0 === layer } ?? false)
        XCTAssertNotNil(VideoRenderRegistry.binding(for: track))
        XCTAssertEqual(capture.calls, [.start("builtin"), .updateFormat(
            try VideoFormat(width: 1024, height: 1920, pixelFormat: .nv12), 24
        )])
        await controller.stopLocalCameraStream()
    }

    func testUnsupportedFormatDoesNotChangeCaptureOrTrack() async throws {
        let capture = CameraCaptureManagingStub(devices: [builtIn])
        let controller = makeController(capture)
        let local = try await controller.createLocalCameraStream(videoFormat: format, deviceID: nil)
        do {
            try await controller.updateVideoFormat(RealtimeVideoFormat(width: 1920, height: 1080, fps: 30))
            XCTFail("Expected unsupported model dimensions")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration) }
        XCTAssertEqual(local.videoTrack?.videoFormat, format)
        XCTAssertEqual(capture.calls, [.start("builtin")])
        await controller.stopLocalCameraStream()
    }

    func testFailedFormatUpdateRetainsPreviousFormatAndCanRetry() async throws {
        let capture = CameraCaptureManagingStub(devices: [builtIn])
        capture.updateError = XmaxError(code: .mediaError, message: "Reconfiguration failed")
        let controller = makeController(capture)
        let local = try await controller.createLocalCameraStream(videoFormat: format, deviceID: nil)
        let updated = RealtimeVideoFormat(width: 1024, height: 1920, fps: 24)
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
        let capture = CameraCaptureManagingStub(devices: [builtIn])
        capture.updateHandler = { await gate.wait() }
        let controller = makeController(capture)
        let local = try await controller.createLocalCameraStream(videoFormat: format, deviceID: nil)
        let update = Task { try await controller.updateVideoFormat(
            RealtimeVideoFormat(width: 1024, height: 1920, fps: 24)
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

    private func makeController(
        _ capture: CameraCaptureManagingStub,
        rtc: RtcManagingStub = RtcManagingStub()
    ) -> CameraController {
        CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(),
            mediaService: MediaService(), captureManager: capture
        )
    }
}

private actor CameraFormatGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

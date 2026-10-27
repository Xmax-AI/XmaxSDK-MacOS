import AppKit
@preconcurrency import AVFoundation
import XCTest
@testable import XmaxSDK

final class AgoraCameraCaptureManagerTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testNativeFormatUpdateRetainsCanvasAndDoesNotRestartStreamOwnership() async throws {
        let rtc = RtcManagingStub()
        let devices = [CameraDevice(id: "usb", name: "USB", isDefault: true, position: .unspecified)]
        let controller = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { devices })
        )
        let stream = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1920, height: 1080, fps: 30), deviceID: nil, mirror: true
        )
        let track = try XCTUnwrap(stream.videoTrack)
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        let canvas = try XCTUnwrap(view.subviews.first)
        try await controller.updateVideoFormat(RealtimeVideoFormat(width: 1080, height: 1920, fps: 24))
        XCTAssertTrue(controller.currentTrack === track)
        XCTAssertTrue(view.subviews.first === canvas)
        XCTAssertEqual(rtc.calls.last, .updateCameraCapture(
            try VideoFormat(width: 1080, height: 1920, pixelFormat: .nv12), 24
        ))
        XCTAssertFalse(rtc.calls.contains(.stopCameraCapture))
        XCTAssertFalse(rtc.calls.contains(.detachCameraPreview))
        XCTAssertEqual(rtc.cameraMirrors, [true])
        await controller.stopLocalCameraStream()
    }

    func testNativeStartupCanBeCancelledWhileWaitingForCaptureMetadata() async throws {
        let rtc = RtcManagingStub()
        rtc.reportsCameraReadyOnStart = false
        let started = expectation(description: "Capture command issued")
        rtc.cameraStartHandler = { started.fulfill() }
        let capture = AgoraCameraCaptureManager(rtcManager: rtc)
        let task = Task {
            try await capture.start(videoFormat: VideoFormat(width: 4, height: 4, pixelFormat: .nv12),
                                    frameRate: 30, deviceID: "test", frameListener: { _ in }, errorListener: { _ in })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as? XmaxError)?.code == .cancelled) }
        await capture.stop()
    }

    func testNativeStartupTimesOutWithoutAFrameObserverOrCaptureReadyEvent() async {
        let rtc = RtcManagingStub()
        rtc.reportsCameraReadyOnStart = false
        let capture = AgoraCameraCaptureManager(rtcManager: rtc, startupTimeout: .milliseconds(30))
        do {
            try await capture.start(videoFormat: VideoFormat(width: 4, height: 4, pixelFormat: .nv12),
                                    frameRate: 30, deviceID: "test", frameListener: { _ in }, errorListener: { _ in })
            XCTFail("Expected capture readiness timeout")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .timeout) }
        await capture.stop()
    }

    @MainActor
    func testNativeCaptureReadinessAndMirroringWithoutRepublishingObservedFrames() async throws {
        let rtc = RtcManagingStub()
        let devices = [CameraDevice(id: "builtin", name: "Camera", isDefault: true, position: .front)]
        let capture = AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { devices })
        let controller = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            captureManager: capture,
            videoFrameListener: { _ in XCTFail("Native camera frames must not be republished as external video") }
        )
        let stream = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1920, height: 1080, fps: 30), deviceID: nil
        )
        let track = try XCTUnwrap(stream.videoTrack)
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        XCTAssertEqual(view.subviews.count, 1)
        XCTAssertFalse(view.layer?.sublayers?.contains { $0 is AVSampleBufferDisplayLayer } ?? false)
        XCTAssertEqual(rtc.calls.last, .attachCameraPreview(.fit, mirrored: false))
        XCTAssertEqual(rtc.cameraMirrors, [false])
        let ready = expectation(description: "Native camera frame and bound preview become ready")
        controller.setPreviewReadyHandler { _ in ready.fulfill() }
        rtc.emitCameraPreviewReady()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(rtc.calls, [.startCameraCapture(RtcCameraConfiguration(
            deviceID: "builtin", width: 1920, height: 1080, frameRate: 30
        )), .attachCameraPreview(.fit, mirrored: false)])
        await controller.stopLocalCameraStream()
        XCTAssertEqual(Array(rtc.calls.suffix(2)), [.stopCameraCapture, .detachCameraPreview])
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertNil(controller.currentTrack)
        XCTAssertNil(VideoRenderRegistry.binding(for: track))
    }

    @MainActor
    func testNativeCameraSwitchPreservesTrackAndExplicitPreviewMirror() async throws {
        let rtc = RtcManagingStub()
        let devices = [
            CameraDevice(id: "builtin", name: "Camera", isDefault: true, position: .front),
            CameraDevice(id: "usb", name: "USB", isDefault: false, position: .back)
        ]
        let controller = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { devices })
        )
        let stream = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1920, height: 1080, fps: 30), deviceID: nil
        )
        let track = try XCTUnwrap(stream.videoTrack)
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: track)?.attach(to: view, contentMode: .fit)
        let switched = try await controller.switchCamera(to: "usb")
        XCTAssertTrue(switched.videoTrack === track)
        XCTAssertEqual(track.device?.id, "usb")
        XCTAssertEqual(Array(rtc.calls.suffix(2)), [.switchCameraCapture("usb"), .attachCameraPreview(.fit, mirrored: false)])
        view.isMirrored = true
        XCTAssertEqual(rtc.calls.last, .attachCameraPreview(.fit, mirrored: true))
        await controller.stopLocalCameraStream()
    }

    @MainActor
    func testMicrophoneControlDoesNotBlockInFlightNativeCameraCallback() async throws {
        let rtc = RtcManagingStub()
        let devices = [CameraDevice(id: "builtin", name: "Camera", isDefault: true, position: .front)]
        let controller = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { devices })
        )
        _ = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1920, height: 1080, fps: 30), deviceID: nil, useMicrophone: true
        )
        rtc.audioControlHandler = {
            let returned = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                rtc.emitCameraPreviewReady()
                returned.signal()
            }
            XCTAssertEqual(returned.wait(timeout: .now() + 1), .success,
                           "Audio control must allow an in-flight camera callback to return")
        }
        try controller.startMicrophoneCapture()
        try controller.stopMicrophoneCapture()
        await controller.stopLocalCameraStream()
    }

    @MainActor
    func testLateNativePreviewReadyCannotReviveStoppedCamera() async throws {
        let rtc = RtcManagingStub()
        let devices = [CameraDevice(id: "builtin", name: "Camera", isDefault: true, position: .front)]
        let controller = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { devices })
        )
        let stream = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1920, height: 1080, fps: 30), deviceID: nil
        )
        let view = XmaxRealtimeVideoView()
        try VideoRenderRegistry.binding(for: XCTUnwrap(stream.videoTrack))?.attach(to: view, contentMode: .fill)
        let late = rtc.currentCameraPreviewReadyListener
        let unexpected = expectation(description: "Stopped preview must not become ready")
        unexpected.isInverted = true
        controller.setPreviewReadyHandler { _ in unexpected.fulfill() }
        await controller.stopLocalCameraStream()
        late?()
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertNil(controller.currentTrack)
    }

    @MainActor
    func testNativePreviewRebindDetachesOldCanvasAndKeepsCameraCapture() async throws {
        let rtc = RtcManagingStub()
        let devices = [CameraDevice(id: "builtin", name: "Camera", isDefault: true, position: .front)]
        let controller = CameraController(
            rtcManager: rtc, permissionManager: PermissionManagingStub(), mediaService: MediaService(),
            captureManager: AgoraCameraCaptureManager(rtcManager: rtc, listDevices: { devices })
        )
        let stream = try await controller.createLocalCameraStream(
            videoFormat: RealtimeVideoFormat(width: 1920, height: 1080, fps: 30), deviceID: nil
        )
        let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: XCTUnwrap(stream.videoTrack)))
        let old = XmaxRealtimeVideoView()
        let next = XmaxRealtimeVideoView()
        try binding.attach(to: old, contentMode: .fill)
        try binding.attach(to: next, contentMode: .fit)
        XCTAssertTrue(old.subviews.isEmpty)
        XCTAssertEqual(next.subviews.count, 1)
        XCTAssertEqual(Array(rtc.calls.suffix(2)), [.detachCameraPreview, .attachCameraPreview(.fit, mirrored: false)])
        XCTAssertFalse(rtc.calls.contains(.stopCameraCapture))
        await controller.stopLocalCameraStream()
    }
}

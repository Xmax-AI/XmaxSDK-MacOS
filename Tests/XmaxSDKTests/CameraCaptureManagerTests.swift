//
//  CameraCaptureManagerTests.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AVFoundation
import XCTest
@testable import XmaxSDK

final class CameraCaptureManagerTests: XCTestCase {

    @MainActor
    func testUpdatingInactiveCaptureDoesNotStartCamera() async throws {
        let capture = CameraCaptureManager()
        do {
            try await capture.updateFormat(VideoFormat(width: 4, height: 4, pixelFormat: .nv12), frameRate: 30)
            XCTFail("Expected inactive capture rejection")
        } catch { XCTAssertEqual((error as? XmaxError)?.code, .mediaError) }
        await capture.stop()
    }

    private var externalDeviceType: AVCaptureDevice.DeviceType {
        if #available(macOS 14.0, *) {
            return .external
        } else {
            return .externalUnknown
        }
    }

    func testStudioDisplayRoundedRateUsesExactDeviceDuration() {
        let duration = CMTime(value: 333333, timescale: 10_000_000)
        XCTAssertEqual(CameraCaptureManager.captureFrameDuration(frameRate: 30, minimum: duration, maximum: duration), duration)
    }

    func testRequestedRateWithinDeviceRangeIsPreserved() {
        let requested = CMTime(value: 1, timescale: 30)
        XCTAssertEqual(CameraCaptureManager.captureFrameDuration(
            frameRate: 30, minimum: CMTime(value: 1, timescale: 60), maximum: CMTime(value: 1, timescale: 15)
        ), requested)
    }

    func testUnsupportedRateDoesNotFallBackToAnotherFrameRate() {
        let duration = CMTime(value: 1, timescale: 25)
        XCTAssertNil(CameraCaptureManager.captureFrameDuration(frameRate: 30, minimum: duration, maximum: duration))
    }

    func testInvalidFrameRateAndDurationAreRejected() {
        let duration = CMTime(value: 1, timescale: 30)
        XCTAssertNil(CameraCaptureManager.captureFrameDuration(frameRate: 0, minimum: duration, maximum: duration))
        XCTAssertNil(CameraCaptureManager.captureFrameDuration(frameRate: 30, minimum: .invalid, maximum: duration))
        XCTAssertNil(CameraCaptureManager.captureFrameDuration(frameRate: 30, minimum: .zero, maximum: duration))
        XCTAssertNil(CameraCaptureManager.captureFrameDuration(frameRate: 30, minimum: duration, maximum: .zero))
    }

    func testBuiltInCameraWithoutReportedPositionUsesFrontMirrorPolicy() {
        XCTAssertEqual(
            CameraCaptureManager.resolvePosition(.unspecified, deviceType: .builtInWideAngleCamera),
            .front
        )
    }

    func testReportedPositionTakesPrecedenceOverDeviceType() {
        for position in [AVCaptureDevice.Position.front, .back] {
            XCTAssertEqual(
                CameraCaptureManager.resolvePosition(position, deviceType: .builtInWideAngleCamera),
                position == .front ? .front : .back
            )
            XCTAssertEqual(
                CameraCaptureManager.resolvePosition(position, deviceType: externalDeviceType),
                position == .front ? .front : .back
            )
        }
    }

    func testExternalCameraWithoutReportedPositionRemainsUnspecified() {
        XCTAssertEqual(
            CameraCaptureManager.resolvePosition(.unspecified, deviceType: externalDeviceType),
            .unspecified
        )
        if #available(macOS 14.0, *) {
            XCTAssertEqual(
                CameraCaptureManager.resolvePosition(.unspecified, deviceType: .continuityCamera),
                .unspecified
            )
        }
    }
}

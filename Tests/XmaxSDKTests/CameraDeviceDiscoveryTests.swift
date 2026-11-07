//
//  CameraDeviceDiscoveryTests.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AVFoundation
import XCTest
@testable import XmaxSDK

final class CameraDeviceDiscoveryTests: XCTestCase {

    private var externalDeviceType: AVCaptureDevice.DeviceType {
        if #available(macOS 14.0, *) {
            return .external
        } else {
            return .externalUnknown
        }
    }

    func testBuiltInCameraWithoutReportedPositionUsesFrontMirrorPolicy() {
        XCTAssertEqual(
            CameraDeviceDiscovery.resolvePosition(.unspecified, deviceType: .builtInWideAngleCamera),
            .front
        )
    }

    func testReportedPositionTakesPrecedenceOverDeviceType() {
        for position in [AVCaptureDevice.Position.front, .back] {
            XCTAssertEqual(
                CameraDeviceDiscovery.resolvePosition(position, deviceType: .builtInWideAngleCamera),
                position == .front ? .front : .back
            )
            XCTAssertEqual(
                CameraDeviceDiscovery.resolvePosition(position, deviceType: externalDeviceType),
                position == .front ? .front : .back
            )
        }
    }

    func testExternalCameraWithoutReportedPositionRemainsUnspecified() {
        XCTAssertEqual(
            CameraDeviceDiscovery.resolvePosition(.unspecified, deviceType: externalDeviceType),
            .unspecified
        )
        if #available(macOS 14.0, *) {
            XCTAssertEqual(
                CameraDeviceDiscovery.resolvePosition(.unspecified, deviceType: .continuityCamera),
                .unspecified
            )
        }
    }
}

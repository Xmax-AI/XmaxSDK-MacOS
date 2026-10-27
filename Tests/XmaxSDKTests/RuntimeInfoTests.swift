//
//  RuntimeInfoTests.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import XCTest
@testable import XmaxSDK

final class RuntimeInfoTests: XCTestCase {

    func testPlatformAndGenerationTaskIdentifiersUseMacOS() {
        XCTAssertEqual(RuntimeInfo.current.platform, "macos")
        let taskID = XmaxRealtimeGenerationManager.createTaskID()
        XCTAssertTrue(taskID.hasPrefix("task-"))
        XCTAssertTrue(taskID.hasSuffix("?os=macos"))
    }

    func testDefaultCameraFormatUsesModelSupportedLandscapeBucket() {
        let model = RealtimeModel.x2_1
        let format = model.defaultCameraVideoFormat
        XCTAssertGreaterThan(format.width, format.height)
        XCTAssertTrue(model.supportedVideoFormats.map(\.size).contains(format.size))
    }
}

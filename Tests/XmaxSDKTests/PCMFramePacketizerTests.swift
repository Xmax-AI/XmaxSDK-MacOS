//
//  PCMFramePacketizerTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import XCTest
@testable import XmaxSDK

final class PCMFramePacketizerTests: XCTestCase {
    func testContinuousInputRetainsPartialPacketsAndSampleOffsets() {
        var packetizer = PCMFramePacketizer()
        let samples = pcmData(sample: 3, count: 240)
        for index in 0..<1000 {
            packetizer.append(samples)
            if index.isMultiple(of: 2) {
                XCTAssertNil(packetizer.nextFrame())
            } else {
                let packet = packetizer.nextFrame()
                XCTAssertEqual(packet?.sampleOffset, (index - 1) * 240)
                XCTAssertEqual(packet?.data, samples + samples)
            }
        }
        XCTAssertNil(packetizer.nextFrame())
    }

    func testPacketizesPCMIntoTenMillisecondFrames() {
        let firstFrame = pcmData(sample: 1, count: AudioFrame.samplesPerFrame)
        let secondFrame = pcmData(sample: 2, count: AudioFrame.samplesPerFrame)
        var packetizer = PCMFramePacketizer()
        packetizer.append(firstFrame + secondFrame)

        let first = packetizer.nextFrame()
        XCTAssertEqual(first?.data, firstFrame)
        XCTAssertEqual(first?.sampleOffset, 0)
        let second = packetizer.nextFrame()
        XCTAssertEqual(second?.data, secondFrame)
        XCTAssertEqual(second?.sampleOffset, AudioFrame.samplesPerFrame)
        XCTAssertNil(packetizer.nextFrame())
    }
}

private extension PCMFramePacketizerTests {
    func pcmData(sample: Int16, count: Int) -> Data {
        var samples = Array(repeating: sample, count: count)
        return samples.withUnsafeMutableBytes { Data($0) }
    }
}

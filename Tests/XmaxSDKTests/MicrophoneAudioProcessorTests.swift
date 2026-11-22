//
//  MicrophoneAudioProcessorTests.swift
//  XmaxSDK
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import Foundation
import XCTest
@testable import XmaxSDK

final class MicrophoneAudioProcessorTests: XCTestCase {

    func testProcessorReceivesCameraMicrophonePCMAndPreservesPacketTiming() {
        let original = AudioFrame(data: Data(repeating: 1, count: 960), timestampUs: 123_456_789)
        let replacement = Data(repeating: 2, count: 960)

        let result = original.processed { packet in
            XCTAssertEqual(packet.data, original.data)
            XCTAssertEqual(packet.sampleRate, 48_000)
            XCTAssertEqual(packet.channels, 1)
            XCTAssertEqual(packet.samplesPerChannel, 480)
            XCTAssertEqual(packet.presentationTimeStamp, CMTime(value: original.timestampUs, timescale: 1_000_000))
            return replacement
        }

        XCTAssertEqual(result.data, replacement)
        XCTAssertEqual(result.timestampUs, original.timestampUs)
    }

    func testAbsentOrInvalidProcessedPCMUsesOriginalPacket() {
        let original = AudioFrame(data: Data(repeating: 1, count: 960), timestampUs: 123_456_789)

        XCTAssertEqual(original.processed(by: nil), original)
        XCTAssertEqual(original.processed { _ in nil }, original)
        XCTAssertEqual(original.processed { _ in Data([1, 2]) }, original)
    }
}

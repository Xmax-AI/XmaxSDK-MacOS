//
//  RtcFoundationTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import AgoraRtcKit
import XCTest
@testable import XmaxSDK

final class RtcFoundationTests: XCTestCase {
    func testEncoderConverterPreservesBitratesAndMapsPreferences() {
        let cases: [(VideoEncodingConfiguration.EncoderPreference, AgoraDegradationPreference)] = [
            (.auto, .maintainAuto),
            (.maintainFramerate, .maintainFramerate),
            (.maintainQuality, .maintainQuality)
        ]
        for (preference, expected) in cases {
            let converted = RtcVideoConverter.makeEncoderConfiguration(VideoEncodingConfiguration(
                width: 832, height: 1472, frameRate: 24,
                minimumBitrate: 1500, maximumBitrate: 3000,
                encoderPreference: preference
            ))
            XCTAssertEqual(converted.dimensions.width, 832)
            XCTAssertEqual(converted.dimensions.height, 1472)
            XCTAssertEqual(converted.frameRate, 24)
            XCTAssertEqual(converted.minBitrate, 1500)
            XCTAssertEqual(converted.bitrate, 3000)
            XCTAssertEqual(converted.degradationPreference, expected)
            XCTAssertEqual(converted.mirrorMode, .disabled)
        }
    }


    func testVideoEncodingConfigurationUsesAdaptiveBitrateDefaults() {
        let configuration = VideoEncodingConfiguration(width: 720, height: 1280, frameRate: 24)
        XCTAssertEqual(configuration.minimumBitrate, 0)
        XCTAssertEqual(configuration.maximumBitrate, -1)
        XCTAssertEqual(configuration.encoderPreference, .maintainFramerate)
        XCTAssertEqual(
            RtcVideoConverter.makeEncoderConfiguration(configuration).degradationPreference,
            .maintainFramerate
        )
    }

    func testQualityConverterMapsKnownAndUnsupportedLevels() {
        for level in RtcQualityLevel.allCases {
            let agora = AgoraNetworkQuality(rawValue: UInt(level.rawValue))!
            XCTAssertEqual(RtcQualityConverter.convertLevel(agora), level)
        }
        XCTAssertEqual(RtcQualityConverter.convertLevel(.detecting), .unknown)
    }

    func testAudioConverterPreservesPCMDataAndRejectsIncompleteFrame() throws {
        let data = Data(repeating: 7, count: 960)
        XCTAssertEqual(try RtcAudioConverter.convertFrame(AudioFrame(data: data, timestampUs: 10000)), data)
        XCTAssertThrowsError(try RtcAudioConverter.convertFrame(AudioFrame(data: Data(repeating: 0, count: 958), timestampUs: 0)))
    }

    func testVideoConverterOwnsSelectedPlaneRangesAndRemovesPadding() throws {
        let frame = try VideoFrame(
            format: VideoFormat(width: 2, height: 2, pixelFormat: .nv12),
            timestampUs: 12345,
            planes: [
                VideoFramePlane(data: Data([99, 1, 2, 88, 3, 4, 98]), stride: 3, byteOffset: 1, byteLength: 5),
                VideoFramePlane(data: Data([97, 5, 6, 96]), stride: 2, byteOffset: 1, byteLength: 2)
            ]
        )
        let converted = try RtcVideoConverter.convertFrame(frame)
        XCTAssertEqual(converted.format, 8)
        XCTAssertEqual(converted.strideInPixels, 2)
        XCTAssertEqual(converted.height, 2)
        XCTAssertEqual(converted.rotation, 0)
        XCTAssertEqual(converted.dataBuf, Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(CMTimeConvertScale(converted.time, timescale: 1000000, method: .default).value, 12345)
    }

    func testVideoConverterRetainsDataAfterSourceIsReleased() throws {
        let converted = try autoreleasepool {
            var data = Data((0..<24).map(UInt8.init))
            let frame = try VideoFrame(
                format: VideoFormat(width: 4, height: 4, pixelFormat: .nv12), timestampUs: 0,
                planes: [
                    VideoFramePlane(data: data, stride: 4, byteLength: 16),
                    VideoFramePlane(data: data, stride: 4, byteOffset: 16, byteLength: 8)
                ]
            )
            let result = try RtcVideoConverter.convertFrame(frame)
            data[0] = 255
            return result
        }
        XCTAssertEqual(converted.dataBuf, Data((0..<24).map(UInt8.init)))
    }

    func testVideoConverterRepacksAdjacentPlaneRangesFromDifferentStorage() throws {
        let frame = try VideoFrame(
            format: VideoFormat(width: 4, height: 4, pixelFormat: .nv12), timestampUs: 0,
            planes: [
                VideoFramePlane(data: Data(repeating: 1, count: 24), stride: 4, byteLength: 16),
                VideoFramePlane(data: Data(repeating: 2, count: 24), stride: 4, byteOffset: 16, byteLength: 8)
            ]
        )
        let converted = try RtcVideoConverter.convertFrame(frame)
        XCTAssertEqual(converted.dataBuf, Data(repeating: 1, count: 16) + Data(repeating: 2, count: 8))
    }

    func testExternalVideoPixelsReachAgoraForBothFormatsAfterSourceRelease() throws {
        for (format, agoraFormat, expected) in [
            (kCVPixelFormatType_32BGRA, 2, Data(repeating: 31, count: 64)),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8,
             Data(repeating: 31, count: 16) + Data(repeating: 97, count: 8))
        ] {
            let converted = try autoreleasepool {
                var buffer: CVPixelBuffer?
                let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary
                XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, format, attributes, &buffer), kCVReturnSuccess)
                let source = try XCTUnwrap(buffer)
                XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
                if format == kCVPixelFormatType_32BGRA {
                    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source))
                    memset(base, 31, CVPixelBufferGetBytesPerRow(source) * 4)
                } else {
                    let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 0))
                    let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, 1))
                    memset(luma, 31, CVPixelBufferGetBytesPerRowOfPlane(source, 0) * 4)
                    memset(chroma, 97, CVPixelBufferGetBytesPerRowOfPlane(source, 1) * 2)
                }
                CVPixelBufferUnlockBaseAddress(source, [])
                let frame = try VideoFrameConverter.convert(
                    pixelBuffer: source, outputWidth: 4, outputHeight: 4, timestampUs: 42
                )
                return try RtcVideoConverter.convertFrame(frame)
            }
            XCTAssertEqual(converted.dataBuf, expected)
            XCTAssertEqual(converted.format, agoraFormat)
            XCTAssertEqual(converted.time, CMTime(value: 42, timescale: 1_000_000))
        }
    }

    func testNativeCameraFrameScalesIntoTheBufferPassedToAgora() throws {
        for (pixelFormat, agoraFormat) in [
            (kCVPixelFormatType_32BGRA, AgoraVideoFormat.cvPixelBGRA),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, AgoraVideoFormat.cvPixelNV12)
        ] {
            var sourceBuffer: CVPixelBuffer?
            var outputBuffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            XCTAssertEqual(CVPixelBufferCreate(nil, 16, 8, pixelFormat, attributes, &sourceBuffer), kCVReturnSuccess)
            XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, pixelFormat, attributes, &outputBuffer), kCVReturnSuccess)
            let source = try XCTUnwrap(sourceBuffer)
            let output = try XCTUnwrap(outputBuffer)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
            let isNV12 = agoraFormat == .cvPixelNV12
            if isNV12 {
                memset(CVPixelBufferGetBaseAddressOfPlane(source, 0), 64, CVPixelBufferGetBytesPerRowOfPlane(source, 0) * 8)
                memset(CVPixelBufferGetBaseAddressOfPlane(source, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(source, 1) * 4)
            } else {
                memset(CVPixelBufferGetBaseAddress(source), 64, CVPixelBufferGetBytesPerRow(source) * 8)
            }
            CVPixelBufferUnlockBaseAddress(source, [])

            let frame = try VideoFrameConverter.convert(
                pixelBuffer: source,
                outputWidth: 4,
                outputHeight: 4,
                timestampUs: 42,
                outputPixelBuffer: output
            )
            guard case .pixelBuffer(let retainedBuffer) = frame.storage else {
                return XCTFail("Expected a native camera buffer")
            }
            let agoraFrame = try RtcVideoConverter.convertFrame(frame)
            XCTAssertTrue(retainedBuffer === output)
            XCTAssertTrue(agoraFrame.textureBuf === retainedBuffer)
            XCTAssertEqual(agoraFrame.format, agoraFormat.rawValue)
            XCTAssertEqual(agoraFrame.time, CMTime(value: 42, timescale: 1_000_000))
            XCTAssertEqual(CVPixelBufferLockBaseAddress(output, .readOnly), kCVReturnSuccess)
            defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
            let firstPlane = isNV12 ? CVPixelBufferGetBaseAddressOfPlane(output, 0) : CVPixelBufferGetBaseAddress(output)
            XCTAssertEqual(try XCTUnwrap(firstPlane).load(as: UInt8.self), 64)
            if isNV12 {
                XCTAssertEqual(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, 1)).load(as: UInt8.self), 128)
            }
        }
    }

    func testVideoConverterRejectsWrongPlaneCountAndShortRows() throws {
        let missingPlane = try VideoFrame(
            format: VideoFormat(width: 2, height: 2, pixelFormat: .nv12), timestampUs: 0,
            planes: [VideoFramePlane(data: Data(repeating: 0, count: 4), stride: 2)]
        )
        XCTAssertThrowsError(try RtcVideoConverter.convertFrame(missingPlane))
        let shortPlane = try VideoFrame(
            format: VideoFormat(width: 2, height: 2, pixelFormat: .bgra), timestampUs: 0,
            planes: [VideoFramePlane(data: Data(repeating: 0, count: 8), stride: 8)]
        )
        XCTAssertThrowsError(try RtcVideoConverter.convertFrame(shortPlane))
    }
}

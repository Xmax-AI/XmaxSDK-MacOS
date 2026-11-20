//
//  CameraFrameProcessingTests.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreVideo
import XCTest
@testable import XmaxSDK

final class CameraFrameProcessingTests: XCTestCase {

    func testRotationThenMirrorPreservesBGRAPixelsAndNV12ChromaPairs() throws {
        for pixelFormat in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            let source = try makeSource(pixelFormat: pixelFormat)
            for rotation in CameraRotation.allCases {
                for mirror in [false, true] {
                    let width = rotation.swapsDimensions ? 4 : 8
                    let height = rotation.swapsDimensions ? 8 : 4
                    var destination: CVPixelBuffer?
                    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, pixelFormat, nil, &destination), kCVReturnSuccess)
                    let frame = try VideoFrameConverter.convert(
                        pixelBuffer: source,
                        outputWidth: width,
                        outputHeight: height,
                        timestampUs: 42,
                        outputPixelBuffer: destination,
                        rotation: rotation,
                        mirror: mirror
                    )
                    guard case .pixelBuffer(let output) = frame.storage else {
                        return XCTFail("Expected the shared output buffer")
                    }
                    XCTAssertTrue(output === destination)
                    XCTAssertEqual(frame.timestampUs, 42)
                    let isNV12 = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    XCTAssertEqual(CVPixelBufferLockBaseAddress(output, .readOnly), kCVReturnSuccess)
                    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
                    for plane in 0..<(isNV12 ? 2 : 1) {
                        let planeWidth = plane == 1 ? width / 2 : width
                        let planeHeight = plane == 1 ? height / 2 : height
                        let bytesPerPixel = isNV12 ? plane + 1 : 4
                        let base = try XCTUnwrap(isNV12
                            ? CVPixelBufferGetBaseAddressOfPlane(output, plane) : CVPixelBufferGetBaseAddress(output))
                        let stride = isNV12 ? CVPixelBufferGetBytesPerRowOfPlane(output, plane) : CVPixelBufferGetBytesPerRow(output)
                        for y in 0..<planeHeight {
                            for x in 0..<planeWidth {
                                let sourceWidth = plane == 1 ? 4 : 8
                                let sourceHeight = plane == 1 ? 2 : 4
                                let point = sourcePoint(
                                    x: mirror ? planeWidth - 1 - x : x,
                                    y: y,
                                    width: sourceWidth,
                                    height: sourceHeight,
                                    rotation: rotation
                                )
                                let actual = base.advanced(by: y * stride + x * bytesPerPixel).assumingMemoryBound(to: UInt8.self)
                                for channel in 0..<bytesPerPixel {
                                    XCTAssertEqual(
                                        actual[channel], marker(x: point.x, y: point.y, plane: plane, channel: channel),
                                        "format \(pixelFormat), rotation \(rotation), mirror \(mirror), plane \(plane), \(x),\(y)"
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testQuarterTurnCropsForTheFinalAspectRatioBeforeRotating() throws {
        let source = try makeSource(pixelFormat: kCVPixelFormatType_32BGRA)
        let frame = try VideoFrameConverter.convert(
            pixelBuffer: source, outputWidth: 4, outputHeight: 4,
            timestampUs: 0, rotation: .degrees90, mirror: true
        )
        guard case .planes(let planes) = frame.storage else { return XCTFail("Expected byte planes") }
        let pixels = planes[0].data
        for y in 0..<4 {
            for x in 0..<4 {
                XCTAssertEqual(pixels[(y * 4 + x) * 4], marker(x: y + 2, y: x, plane: 0, channel: 0))
            }
        }
    }

    private func makeSource(pixelFormat: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            nil, 8, 4, pixelFormat,
            [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &buffer
        ), kCVReturnSuccess)
        let source = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(source, []) }
        let isNV12 = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        for plane in 0..<(isNV12 ? 2 : 1) {
            let width = plane == 1 ? 4 : 8
            let height = plane == 1 ? 2 : 4
            let bytesPerPixel = isNV12 ? plane + 1 : 4
            let base = try XCTUnwrap(isNV12
                ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source))
            let stride = isNV12 ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            memset(base, 255, stride * height)
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = base.advanced(by: y * stride + x * bytesPerPixel).assumingMemoryBound(to: UInt8.self)
                    for channel in 0..<bytesPerPixel {
                        pixel[channel] = marker(x: x, y: y, plane: plane, channel: channel)
                    }
                }
            }
        }
        return source
    }

    private func marker(x: Int, y: Int, plane: Int, channel: Int) -> UInt8 {
        UInt8(16 + x + y * 8 + plane * 64 + channel * 32)
    }

    private func sourcePoint(x: Int, y: Int, width: Int, height: Int, rotation: CameraRotation) -> (x: Int, y: Int) {
        switch rotation {
        case .degrees0: (x, y)
        case .degrees90: (y, height - 1 - x)
        case .degrees180: (width - 1 - x, height - 1 - y)
        case .degrees270: (width - 1 - y, x)
        }
    }
}

import CoreVideo
import Foundation
import XCTest
import BeautyBridge
import BeautyIPC
@testable import XmaxRealtimeBeautyWorkerSupport

/// Tests the worker's vendor graph directly, without running a host app, an XPC service, or RTC.
final class BeautyWorkerTests: XCTestCase {
    func testMissedFrameRetiresGraphBeforeReconnectAndIgnoresLateClose() throws {
        let engine = BeautyWorkerEngine()
        let disconnected = BeautyWorkerContext()
        let reconnected = BeautyWorkerContext()
        let options = options(lightening: 0.5)
        let appID = "5588dfe2e7874bd08ea28f4968ec2d40"
        try engine.worker.sync {
            defer { engine.close(reconnected) }
            let original = try engine.prepare(appID: appID, options: options, for: disconnected)
            let failure = NSError(domain: "ai.xmax.video-beauty", code: BeautyWorkerFrameStatus.unavailable.rawValue)
            XCTAssertEqual(engine.frameFailureCode(failure, for: disconnected), failure.code)
            XCTAssertTrue(disconnected.closed)
            XCTAssertThrowsError(try original.updateOptions(options))

            let replacement = try engine.prepare(appID: appID, options: options, for: reconnected)
            XCTAssertFalse(original === replacement)
            engine.close(disconnected)
            XCTAssertTrue(replacement === (try engine.prepare(appID: appID, options: options, for: reconnected)))
            try replacement.updateOptions(options)
        }
    }

    func testBufferPoolPressureRecoversAfterConsumersReleaseFrames() throws {
        let processor = try BeautyProcessor(appID: "5588dfe2e7874bd08ea28f4968ec2d40", options: options(lightening: 0.5))
        defer { processor.close() }
        let input = try makePixels()
        var retained: [CVPixelBuffer] = []
        for _ in 0..<16 {
            retained.append(try autoreleasepool { try processor.processPixelBuffer(input) })
        }
        let heldValue = luminance(retained[0])
        XCTAssertThrowsError(try processor.processPixelBuffer(input)) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "ai.xmax.video-beauty")
            XCTAssertEqual(failure.code, Int(kCVReturnWouldExceedAllocationThreshold))
        }
        XCTAssertEqual(luminance(retained[0]), heldValue, "Pressure must not overwrite retained output")
        retained.removeAll()
        let recovered = try processor.processPixelBuffer(input)
        XCTAssertEqual(luminance(recovered), heldValue)
    }

    func testPixelsBurstOwnershipAndRecreation() throws {
        let processor = try BeautyProcessor(appID: "5588dfe2e7874bd08ea28f4968ec2d40", options: options(lightening: 1))
        let input = try makePixels()
        let bright = try processor.processPixelBuffer(input)
        let brightValue = luminance(bright)
        try processor.updateOptions(options(lightening: 0))
        let neutral = try processor.processPixelBuffer(input)
        let neutralValue = luminance(neutral)
        XCTAssertGreaterThan(brightValue, neutralValue + 5)
        try processor.updateOptions(options(lightening: 1))
        for _ in 0..<24 {
            let output = try processor.processPixelBuffer(neutral)
            XCTAssertEqual(CVPixelBufferGetWidth(output), 320)
            XCTAssertEqual(CVPixelBufferGetHeight(output), 240)
            XCTAssertGreaterThan(luminance(output), neutralValue + 5)
        }
        XCTAssertEqual(luminance(bright), brightValue, "Retained pool buffers must stay immutable")
        XCTAssertEqual(luminance(neutral), neutralValue)
        try processor.updateOptions(options(lightening: 0))
        var fullRange: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &fullRange), kCVReturnSuccess)
        let full = try XCTUnwrap(fullRange)
        CVPixelBufferLockBaseAddress(full, [])
        CVPixelBufferLockBaseAddress(neutral, .readOnly)
        for plane in 0..<2 {
            let source = CVPixelBufferGetBaseAddressOfPlane(neutral, plane)!.assumingMemoryBound(to: UInt8.self)
            let destination = CVPixelBufferGetBaseAddressOfPlane(full, plane)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<(plane == 0 ? 240 : 120) {
                for column in 0..<320 {
                    let value = Int(source[row * CVPixelBufferGetBytesPerRowOfPlane(neutral, plane) + column])
                    let scale = plane == 0 ? 219 : 224
                    destination[row * CVPixelBufferGetBytesPerRowOfPlane(full, plane) + column] = UInt8(clamping: ((value - 16) * 255 + scale / 2) / scale)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(neutral, .readOnly)
        CVPixelBufferUnlockBaseAddress(full, [])
        let normalized = try processor.processPixelBuffer(full)
        XCTAssertEqual(luminance(normalized), neutralValue, accuracy: 2)
        processor.close()
        processor.close()
        let next = try BeautyProcessor(appID: "5588dfe2e7874bd08ea28f4968ec2d40", options: options(lightening: 1))
        let output = try next.processPixelBuffer(input)
        XCTAssertGreaterThan(luminance(output), neutralValue + 5)
        next.close()
    }

    private func options(lightening: Float) -> [String: NSNumber] {
        ["enable": true, "lightness": NSNumber(value: lightening), "smoothness": 0,
         "sharpness": 0, "redness": 0, "contrast": 1]
    }

    private func makePixels() throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let input = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(input, [])
        let base = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<240 {
            for column in 0..<320 {
                let offset = row * CVPixelBufferGetBytesPerRow(input) + column * 4
                base[offset] = 80
                base[offset + 1] = 100
                base[offset + 2] = 130
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        return input
    }

    private func luminance(_ pixels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        return Int(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)[1000])
    }
}

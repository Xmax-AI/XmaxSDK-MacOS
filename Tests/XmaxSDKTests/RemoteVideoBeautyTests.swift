import CoreMedia
import CoreVideo
import XCTest
@testable import XmaxSDK

final class RemoteVideoBeautyTests: XCTestCase, @unchecked Sendable {
    func testOutputPressureDropsOneFrameAndPreservesBeautyForNextFrame() async throws {
        let replacement = try frame()
        let pressure = expectation(description: "Pool pressure observed")
        let resumed = expectation(description: "Next frame retains beauty")
        let processor = BeautyStub(replacement: replacement.pixelBuffer, pressureObserved: pressure)
        let pipeline = makePipeline(factory: { _ in processor }, output: { frame, _ in
            XCTAssertTrue(frame.pixelBuffer === replacement.pixelBuffer)
            XCTAssertEqual(frame.presentationTimeStamp.value, 2)
            resumed.fulfill()
        })
        await pipeline.setRemoteVideoBeautyErrorListener { _ in
            XCTFail("Temporary capacity pressure must not disable beauty or notify the user")
        }
        try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions())
        await pipeline.enqueue(try frame())
        await fulfillment(of: [pressure], timeout: 2)
        await pipeline.enqueue(try frame(timestamp: 2))
        await fulfillment(of: [resumed], timeout: 2)
        let calls = await processor.calls
        XCTAssertEqual(calls, 2)
        await pipeline.closeBeauty()
    }

    func testRejectsInvalidStrengthsBeforeCreatingProcessor() async throws {
        for value: Float in [-0.1, 1.1, .nan, .infinity, -.infinity] {
            let pipeline = makePipeline(factory: { _ in
                XCTFail("Invalid options must not initialize native resources")
                throw XmaxError(code: .internalError, message: "Unexpected factory")
            })
            do {
                try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions(smoothness: value))
                XCTFail("Expected validation failure")
            } catch let error as XmaxError {
                XCTAssertEqual(error.code, .invalidConfiguration)
            }
        }
        XCTAssertThrowsError(try RealtimeVideoBeautyOptions(lightening: .nan).validate())
        XCTAssertThrowsError(try RealtimeVideoBeautyOptions(sharpness: 1.1).validate())
        XCTAssertThrowsError(try RealtimeVideoBeautyOptions(redness: -.infinity).validate())
    }

    func testBeautyIsEnabledWithZeroStrengthsByDefaultAndPreservesTimestamp() async throws {
        let input = try frame()
        let replacement = try frame()
        let processor = BeautyStub(replacement: replacement.pixelBuffer)
        let recorder = BeautyRecorder()
        let output = expectation(description: "Processed output")
        let pipeline = makePipeline(factory: { options in
            XCTAssertEqual(options.smoothness, 0)
            XCTAssertEqual(options.lightening, 0)
            XCTAssertEqual(options.sharpness, 0)
            XCTAssertEqual(options.redness, 0)
            return processor
        }, output: { frame, _ in
            await recorder.append(frame)
            output.fulfill()
        })
        await pipeline.enqueue(input)
        await fulfillment(of: [output], timeout: 2)
        let recorded = await recorder.first()
        let received = try XCTUnwrap(recorded)
        XCTAssertTrue(received.pixelBuffer === replacement.pixelBuffer)
        XCTAssertEqual(received.presentationTimeStamp, input.presentationTimeStamp)
        XCTAssertEqual(received.duration, CMTime(value: 1, timescale: 24))
        await pipeline.closeBeauty()
    }

    func testExplicitDisableBypassesBeautyAndCloseRestoresDefaults() async throws {
        let input = try frame()
        let replacement = try frame()
        let bypassed = expectation(description: "Explicit disable preserves original pixels")
        let restored = expectation(description: "Reused pipeline restores beauty defaults")
        let processor = BeautyStub(replacement: replacement.pixelBuffer)
        let pipeline = makePipeline(factory: { options in
            XCTAssertEqual(options, RealtimeVideoBeautyOptions(smoothness: 0, lightening: 0, sharpness: 0, redness: 0))
            return processor
        }, output: { frame, _ in
            if frame.presentationTimeStamp.value == 1 {
                XCTAssertTrue(frame.pixelBuffer === input.pixelBuffer)
                bypassed.fulfill()
            } else {
                XCTAssertTrue(frame.pixelBuffer === replacement.pixelBuffer)
                restored.fulfill()
            }
        })
        try await pipeline.setRemoteVideoBeauty(nil)
        await pipeline.enqueue(input)
        await fulfillment(of: [bypassed], timeout: 2)
        await pipeline.closeBeauty()
        await pipeline.enqueue(try frame(timestamp: 2))
        await fulfillment(of: [restored], timeout: 2)
        await pipeline.closeBeauty()
    }

    func testFailureFallsBackOnceAndDoesNotReachTerminalErrorListener() async throws {
        let processor = BeautyStub(fails: true)
        let recorder = BeautyRecorder()
        let failed = expectation(description: "Recoverable beauty failure")
        failed.assertForOverFulfill = true
        let first = expectation(description: "First fallback frame")
        let second = expectation(description: "Subsequent original frame")
        let pipeline = makePipeline(factory: { _ in processor }, output: { frame, _ in
            await recorder.append(frame)
            if frame.presentationTimeStamp.value == 1 { first.fulfill() } else { second.fulfill() }
        })
        await pipeline.setRemoteVideoBeautyErrorListener { error in
            XCTAssertEqual(error.code, .mediaError)
            failed.fulfill()
        }
        try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions())
        let input = try frame()
        await pipeline.enqueue(input)
        await fulfillment(of: [failed, first], timeout: 2)
        let recorded = await recorder.first()
        let fallback = try XCTUnwrap(recorded)
        XCTAssertTrue(fallback.pixelBuffer === input.pixelBuffer)
        await pipeline.enqueue(try frame(timestamp: 2))
        await fulfillment(of: [second], timeout: 2)
        let calls = await processor.calls
        XCTAssertEqual(calls, 1)
        await pipeline.closeBeauty()
    }

    func testResetDiscardsInFlightBeautyAndKeepsSettingForNextStream() async throws {
        let entered = expectation(description: "Beauty processing started")
        let processor = BeautyStub(entered: entered)
        let recorder = BeautyRecorder()
        let output = expectation(description: "New stream output")
        let pipeline = makePipeline(factory: { _ in processor }, output: { frame, token in
            XCTAssertEqual(token, 2)
            await recorder.append(frame)
            output.fulfill()
        })
        try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions())
        await pipeline.enqueue(try frame(), outputToken: 0)
        await fulfillment(of: [entered], timeout: 2)
        await pipeline.reset(outputToken: 2)
        let old = await recorder.first()
        XCTAssertNil(old)
        await pipeline.enqueue(try frame(timestamp: 2), outputToken: 2)
        await fulfillment(of: [output], timeout: 2)
        await pipeline.closeBeauty()
    }


    private func makePipeline(
        factory: @escaping RemoteVideoFramePipeline.BeautyProcessorFactory,
        output: @escaping RemoteVideoFramePipeline.OutputListener = { _, _ in }
    ) -> RemoteVideoFramePipeline {
        RemoteVideoFramePipeline(
            interpolationEnabled: false,
            outputToken: 0,
            beautyProcessorFactory: factory,
            outputListener: output,
            errorListener: { _ in XCTFail("Beauty must not enter interpolation/session errors") }
        )
    }

    private func frame(timestamp: Int64 = 1) throws -> RealtimeVideoFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<240 {
            for column in 0..<320 {
                let offset = row * CVPixelBufferGetBytesPerRow(pixels) + column * 4
                base[offset] = 80
                base[offset + 1] = 100
                base[offset + 2] = 130
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return RealtimeVideoFrame(pixelBuffer: pixels, presentationTimeStamp: CMTime(value: timestamp, timescale: 24),
                                  duration: CMTime(value: 1, timescale: 24))
    }

    private func luminance(_ pixels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        return Int(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)[1000])
    }
}

private actor BeautyRecorder {
    private var frames: [RealtimeVideoFrame] = []
    func append(_ frame: RealtimeVideoFrame) { frames.append(frame) }
    func first() -> RealtimeVideoFrame? { frames.first }
}

private actor BeautyStub: VideoBeautyProcessing {
    private let replacement: CVPixelBuffer?
    private let fails: Bool
    private let pressureObserved: XCTestExpectation?
    private let entered: XCTestExpectation?
    private var waiting: CheckedContinuation<Void, Never>?
    private var closed = false
    private(set) var calls = 0

    init(replacement: CVPixelBuffer? = nil, fails: Bool = false, entered: XCTestExpectation? = nil, pressureObserved: XCTestExpectation? = nil) {
        self.replacement = replacement
        self.fails = fails
        self.entered = entered
        self.pressureObserved = pressureObserved
    }
    func update(_ options: RealtimeVideoBeautyOptions) {}
    func process(_ frame: RealtimeVideoFrame) async throws -> RealtimeVideoFrame {
        calls += 1
        if let pressureObserved, calls == 1 {
            pressureObserved.fulfill()
            throw VideoBeautyProcessingError.outputBackpressure
        }
        if let entered, !closed {
            await withCheckedContinuation { continuation in
                waiting = continuation
                entered.fulfill()
            }
        }
        if fails { throw XmaxError(code: .mediaError, message: "Synthetic beauty failure") }
        return RealtimeVideoFrame(pixelBuffer: replacement ?? frame.pixelBuffer,
                                  presentationTimeStamp: frame.presentationTimeStamp, duration: frame.duration)
    }
    func close() {
        closed = true
        waiting?.resume()
        waiting = nil
    }
}

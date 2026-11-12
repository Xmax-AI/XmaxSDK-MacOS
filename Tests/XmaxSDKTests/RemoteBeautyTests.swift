import CoreMedia
import CoreVideo
import XCTest
@testable import XmaxSDK

final class RemoteBeautyTests: XCTestCase, @unchecked Sendable {
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
        try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions(smoothness: 0.5))
        await pipeline.enqueue(try frame(), outputToken: 0)
        await fulfillment(of: [pressure], timeout: 2)
        await pipeline.enqueue(try frame(timestamp: 2), outputToken: 0)
        await fulfillment(of: [resumed], timeout: 2)
        let calls = await processor.calls
        XCTAssertEqual(calls, 2)
        await pipeline.closeBeauty()
    }

    func testMissedFramePassesThroughAndRetriesBeautyOnce() async throws {
        let failure = XmaxError(code: .mediaError, message: "ClearVision did not return a frame")
        let missedFrame = BeautyProcessingError.frameUnavailable(failure)
        for recoveryFails in [false, true] {
            let first = try frame()
            let second = try frame(timestamp: 2)
            let replacement = try frame()
            let initialProcessor = BeautyStub(failure: missedFrame)
            let nextProcessor = BeautyStub(
                replacement: replacement.pixelBuffer,
                failure: recoveryFails ? missedFrame : nil
            )
            let firstOutput = expectation(description: "Missed frame bypasses beauty")
            let secondOutput = expectation(description: "Next frame resumes beauty or falls back")
            let disabled = recoveryFails ? expectation(description: "Repeated failure disables beauty") : nil
            let pipeline = makePipeline(factory: { _ in
                await initialProcessor.calls == 0 ? initialProcessor : nextProcessor
            }, output: { frame, _ in
                if frame.presentationTimeStamp == first.presentationTimeStamp {
                    XCTAssertTrue(frame.pixelBuffer === first.pixelBuffer)
                    firstOutput.fulfill()
                } else {
                    XCTAssertEqual(frame.presentationTimeStamp, second.presentationTimeStamp)
                    XCTAssertTrue(frame.pixelBuffer === (recoveryFails ? second.pixelBuffer : replacement.pixelBuffer))
                    secondOutput.fulfill()
                }
            })
            await pipeline.setRemoteVideoBeautyErrorListener { error in
                if let disabled {
                    XCTAssertEqual(error, failure)
                    disabled.fulfill()
                } else {
                    XCTFail("A single missed frame must not disable beauty")
                }
            }
            try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions(smoothness: 0.5))
            await pipeline.enqueue(first, outputToken: 0)
            await fulfillment(of: [firstOutput], timeout: 2)
            await pipeline.enqueue(second, outputToken: 0)
            await fulfillment(of: [secondOutput] + (disabled.map { [$0] } ?? []), timeout: 2)
            let initialCalls = await initialProcessor.calls
            let recoveryCalls = await nextProcessor.calls
            XCTAssertEqual(initialCalls, 1)
            XCTAssertEqual(recoveryCalls, 1)
            await pipeline.closeBeauty()
        }
    }

    func testSettingsUpdateOwnsRebuildAfterMissedFrame() async throws {
        let oldOptions = RealtimeVideoBeautyOptions(smoothness: 0.5)
        let newOptions = RealtimeVideoBeautyOptions(smoothness: 0.8)
        let missed = try frame()
        let duringUpdate = try frame(timestamp: 2)
        let afterUpdate = try frame(timestamp: 3)
        let staleOutput = try frame()
        let updatedOutput = try frame()
        let initial = BeautyStub(failure: BeautyProcessingError.frameUnavailable(
            XmaxError(code: .mediaError, message: "ClearVision did not return a frame")
        ))
        let stale = BeautyStub(replacement: staleOutput.pixelBuffer)
        let updated = BeautyStub(replacement: updatedOutput.pixelBuffer)
        let missedDelivered = expectation(description: "Missed frame bypasses beauty")
        let configurationStarted = expectation(description: "New settings start creating a processor")
        let duringUpdateDelivered = expectation(description: "Preview continues during configuration")
        let updatedDelivered = expectation(description: "Next frame uses new settings")
        let (configurationGate, resumeConfiguration) = AsyncStream<Void>.makeStream()
        defer { resumeConfiguration.finish() }

        let pipeline = makePipeline(factory: { options in
            if options == oldOptions {
                return await initial.calls == 0 ? initial : stale
            }
            XCTAssertEqual(options, newOptions)
            configurationStarted.fulfill()
            var gate = configurationGate.makeAsyncIterator()
            _ = await gate.next()
            return updated
        }, output: { frame, _ in
            switch frame.presentationTimeStamp.value {
            case 1:
                XCTAssertTrue(frame.pixelBuffer === missed.pixelBuffer)
                missedDelivered.fulfill()
            case 2:
                XCTAssertTrue(frame.pixelBuffer === duringUpdate.pixelBuffer)
                duringUpdateDelivered.fulfill()
            case 3:
                XCTAssertTrue(frame.pixelBuffer === updatedOutput.pixelBuffer)
                updatedDelivered.fulfill()
            default:
                XCTFail("Unexpected output frame")
            }
        })

        try await pipeline.setRemoteVideoBeauty(oldOptions)
        await pipeline.enqueue(missed, outputToken: 0)
        await fulfillment(of: [missedDelivered], timeout: 2)

        let configuration = Task { try await pipeline.setRemoteVideoBeauty(newOptions) }
        await fulfillment(of: [configurationStarted], timeout: 2)
        await pipeline.enqueue(duringUpdate, outputToken: 0)
        await fulfillment(of: [duringUpdateDelivered], timeout: 2)
        resumeConfiguration.finish()
        try await configuration.value

        await pipeline.enqueue(afterUpdate, outputToken: 0)
        await fulfillment(of: [updatedDelivered], timeout: 2)
        let staleCalls = await stale.calls
        XCTAssertEqual(staleCalls, 0)
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

    func testBeautyIsDisabledByDefaultWithoutCreatingProcessor() async throws {
        let input = try frame()
        let output = expectation(description: "Original result output")
        let pipeline = makePipeline(factory: { _ in
            XCTFail("Default-disabled beauty must not initialize a processor")
            throw XmaxError(code: .internalError, message: "Unexpected factory")
        }, output: { frame, _ in
            XCTAssertTrue(frame.pixelBuffer === input.pixelBuffer)
            XCTAssertEqual(frame.presentationTimeStamp, input.presentationTimeStamp)
            output.fulfill()
        })
        await pipeline.enqueue(input, outputToken: 0)
        await fulfillment(of: [output], timeout: 2)
        await pipeline.closeBeauty()
    }

    func testExplicitBeautyEnableProcessesZeroAndNonzeroOptionsAndPreservesTiming() async throws {
        for options in [RealtimeVideoBeautyOptions(),
                        RealtimeVideoBeautyOptions(smoothness: 0.5),
                        RealtimeVideoBeautyOptions(lightening: 0.5),
                        RealtimeVideoBeautyOptions(sharpness: 0.5),
                        RealtimeVideoBeautyOptions(redness: 0.5)] {
            let input = try frame()
            let replacement = try frame()
            let processor = BeautyStub(replacement: replacement.pixelBuffer)
            let output = expectation(description: "Processed output")
            let pipeline = makePipeline(factory: { applied in
                XCTAssertEqual(applied, options)
                return processor
            }, output: { received, _ in
                XCTAssertTrue(received.pixelBuffer === replacement.pixelBuffer)
                XCTAssertEqual(received.presentationTimeStamp, input.presentationTimeStamp)
                XCTAssertEqual(received.duration, input.duration)
                output.fulfill()
            })
            try await pipeline.setRemoteVideoBeauty(options)
            await pipeline.enqueue(input, outputToken: 0)
            await fulfillment(of: [output], timeout: 2)
            await pipeline.closeBeauty()
        }
    }

    func testExplicitDisableAndCloseKeepBeautyDisabled() async throws {
        let input = try frame()
        let afterClose = try frame(timestamp: 2)
        let replacement = try frame()
        let bypassed = expectation(description: "Explicit disable preserves original pixels")
        let restored = expectation(description: "Reused pipeline keeps beauty disabled")
        let processor = BeautyStub(replacement: replacement.pixelBuffer)
        let pipeline = makePipeline(factory: { options in
            XCTAssertEqual(options, RealtimeVideoBeautyOptions(smoothness: 0.5))
            return processor
        }, output: { frame, _ in
            if frame.presentationTimeStamp.value == 1 {
                XCTAssertTrue(frame.pixelBuffer === input.pixelBuffer)
                bypassed.fulfill()
            } else {
                XCTAssertTrue(frame.pixelBuffer === afterClose.pixelBuffer)
                restored.fulfill()
            }
        })
        try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions(smoothness: 0.5))
        try await pipeline.setRemoteVideoBeauty(nil)
        await pipeline.enqueue(input, outputToken: 0)
        await fulfillment(of: [bypassed], timeout: 2)
        await pipeline.closeBeauty()
        await pipeline.enqueue(afterClose, outputToken: 0)
        await fulfillment(of: [restored], timeout: 2)
        await pipeline.closeBeauty()
    }

    func testFailureFallsBackOnceAndDoesNotReachTerminalErrorListener() async throws {
        let processor = BeautyStub(failure: XmaxError(code: .mediaError, message: "Synthetic beauty failure"))
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
        try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions(smoothness: 0.5))
        let input = try frame()
        await pipeline.enqueue(input, outputToken: 0)
        await fulfillment(of: [failed, first], timeout: 2)
        let recorded = await recorder.first()
        let fallback = try XCTUnwrap(recorded)
        XCTAssertTrue(fallback.pixelBuffer === input.pixelBuffer)
        await pipeline.enqueue(try frame(timestamp: 2), outputToken: 0)
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
        try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions(smoothness: 0.5))
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
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
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

private actor BeautyStub: BeautyProcessing {
    private let converter = BeautyColorConverter()
    private let replacement: CVPixelBuffer?
    private let failure: (any Error)?
    private let pressureObserved: XCTestExpectation?
    private let entered: XCTestExpectation?
    private var waiting: CheckedContinuation<Void, Never>?
    private var closed = false
    private(set) var calls = 0

    init(
        replacement: CVPixelBuffer? = nil,
        failure: (any Error)? = nil,
        entered: XCTestExpectation? = nil,
        pressureObserved: XCTestExpectation? = nil
    ) {
        self.replacement = replacement
        self.failure = failure
        self.entered = entered
        self.pressureObserved = pressureObserved
    }
    func update(_ options: RealtimeVideoBeautyOptions) {}
    func process(_ input: BeautyFrameInput) async throws -> RealtimeVideoFrame {
        let frame = try input.resolve(using: converter)
        calls += 1
        if let pressureObserved, calls == 1 {
            pressureObserved.fulfill()
            throw BeautyProcessingError.outputBackpressure
        }
        if let entered, !closed {
            await withCheckedContinuation { continuation in
                waiting = continuation
                entered.fulfill()
            }
        }
        if let failure { throw failure }
        return RealtimeVideoFrame(pixelBuffer: replacement ?? frame.pixelBuffer,
                                  presentationTimeStamp: frame.presentationTimeStamp, duration: frame.duration)
    }
    func close() {
        converter.close()
        closed = true
        waiting?.resume()
        waiting = nil
    }
}

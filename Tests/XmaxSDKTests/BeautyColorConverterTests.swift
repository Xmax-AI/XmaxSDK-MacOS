import CoreImage
import CoreMedia
import CoreVideo
import XCTest
@testable import XmaxSDK

final class BeautyColorConverterTests: XCTestCase, @unchecked Sendable {
    func testCompatibleAndUntaggedFramesRetainOriginalBuffersAndTiming() throws {
        let converter = BeautyColorConverter()
        defer { converter.close() }
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            let input = try makeFrame(format: format)
            let untagged = try converter.prepare(input)
            XCTAssertTrue(untagged.pixelBuffer === input.pixelBuffer)
            setColors(input.pixelBuffer)
            let tagged = try converter.prepare(input)
            XCTAssertTrue(tagged.pixelBuffer === input.pixelBuffer)
            XCTAssertEqual(tagged.presentationTimeStamp, input.presentationTimeStamp)
            XCTAssertEqual(tagged.duration, input.duration)
        }
    }

    func testSDRColorConversionPreservesAppearanceInsteadOfRelabelingPixels() throws {
        let converter = BeautyColorConverter()
        defer { converter.close() }
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            for srgb in [false, true] {
                let input = try makeFrame(format: format)
                setColors(input.pixelBuffer,
                          primaries: srgb ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C,
                          transfer: srgb ? kCVImageBufferTransferFunction_sRGB : kCVImageBufferTransferFunction_ITU_R_709_2,
                          matrix: srgb ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4)
                let before = render(input.pixelBuffer)
                let converted = try converter.prepare(input)
                XCTAssertFalse(converted.pixelBuffer === input.pixelBuffer)
                assertCompatible(converted)
                XCTAssertEqual(converted.presentationTimeStamp, input.presentationTimeStamp)
                XCTAssertEqual(converted.duration, input.duration)
                let after = render(converted.pixelBuffer)
                let maxError = zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(maxError, 5, "Converted SDR must retain its displayed colors")
                XCTAssertEqual(render(input.pixelBuffer), before, "Source pixels and tags must not be changed")
            }
        }
    }

    func testDisabledBeautyPreservesTaggedHDRFrames() async throws {
        for transfer in [kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                         kCVImageBufferTransferFunction_ITU_R_2100_HLG] {
            let input = try makeFrame()
            setColors(input.pixelBuffer, transfer: transfer)
            let transferName = transfer as String
            let output = expectation(description: "Original HDR frame")
            let pipeline = RemoteVideoFramePipeline(
                interpolationEnabled: false,
                outputToken: 0,
                beautyProcessorFactory: { _ in
                    XCTFail("Disabled beauty must not initialize a processor")
                    throw XmaxError(code: .internalError, message: "Unexpected processor")
                },
                outputListener: { frame, _ in
                    XCTAssertTrue(frame.pixelBuffer === input.pixelBuffer)
                    XCTAssertEqual(CVBufferCopyAttachment(frame.pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String,
                                   transferName)
                    output.fulfill()
                },
                errorListener: { _ in XCTFail("Unexpected failure") }
            )
            await pipeline.enqueue(input)
            await fulfillment(of: [output], timeout: 2)
            await pipeline.closeBeauty()
        }
    }

    func testHDRTransferFunctionsFailWithTheirActualValues() throws {
        let converter = BeautyColorConverter()
        for transfer in [kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                         kCVImageBufferTransferFunction_ITU_R_2100_HLG] {
            let input = try makeFrame()
            setColors(input.pixelBuffer, transfer: transfer)
            XCTAssertEqual(CVBufferCopyAttachment(input.pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String,
                           transfer as String)
            XCTAssertThrowsError(try converter.prepare(input), "Expected rejection for \(transfer)") { error in
                let failure = error as? XmaxError
                XCTAssertEqual(failure?.code, .mediaError)
                XCTAssertTrue(failure?.message.contains(transfer as String) == true)
            }
        }
        converter.close()
    }

    func testConvertedBufferPressureAndShutdownPreserveRetainedPixels() throws {
        let converter = BeautyColorConverter()
        let input = try makeFrame()
        setColors(input.pixelBuffer, transfer: kCVImageBufferTransferFunction_sRGB)
        var retained = try (0..<3).map { _ in try converter.prepare(input) }
        let before = render(retained[0].pixelBuffer)
        XCTAssertThrowsError(try converter.prepare(input)) { error in
            guard case BeautyProcessingError.outputBackpressure = error else {
                return XCTFail("Expected recoverable conversion pool pressure")
            }
        }
        XCTAssertEqual(render(retained[0].pixelBuffer), before)
        retained.removeLast()
        let recovered = try converter.prepare(input)
        assertCompatible(recovered)
        converter.close()
        XCTAssertEqual(render(retained[0].pixelBuffer), before)
    }

    func testDisabledAndZeroStrengthBeautyShareTheSameResultColorProfile() async throws {
        let input = try makeFrame()
        setColors(input.pixelBuffer, primaries: kCVImageBufferColorPrimaries_SMPTE_C,
                  matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        CVPixelBufferLockBaseAddress(input.pixelBuffer, [])
        let chroma = CVPixelBufferGetBaseAddressOfPlane(input.pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(input.pixelBuffer, 1)
        for row in 0..<120 {
            for column in stride(from: 0, to: 320, by: 2) {
                chroma[row * rowBytes + column] = 80
                chroma[row * rowBytes + column + 1] = 170
            }
        }
        CVPixelBufferUnlockBaseAddress(input.pixelBuffer, [])
        let originalColors = render(input.pixelBuffer)
        let processor = ColorReferenceBeautyProcessor()
        let recorder = ResultColorFrameRecorder()
        let first = expectation(description: "Initially disabled result")
        let second = expectation(description: "Explicit zero-strength result")
        let third = expectation(description: "Disabled again result")
        let initialized = expectation(description: "Only explicit beauty initializes the processor")
        let pipeline = RemoteVideoFramePipeline(
            interpolationEnabled: false,
            outputToken: 0,
            beautyProcessorFactory: { options in
                XCTAssertEqual(options, RealtimeVideoBeautyOptions())
                initialized.fulfill()
                return processor
            },
            outputListener: { frame, _ in
                await recorder.append(frame)
                switch frame.presentationTimeStamp.value {
                case 123: first.fulfill()
                case 124: second.fulfill()
                case 125: third.fulfill()
                default: XCTFail("Unexpected output timestamp")
                }
            },
            errorListener: { _ in XCTFail("Output color preparation must not end generation") }
        )
        await pipeline.enqueue(input)
        await fulfillment(of: [first], timeout: 2)
        try await pipeline.setRemoteVideoBeauty(RealtimeVideoBeautyOptions())
        await pipeline.enqueue(RealtimeVideoFrame(pixelBuffer: input.pixelBuffer,
                                                 presentationTimeStamp: CMTime(value: 124, timescale: 24),
                                                 duration: input.duration))
        await fulfillment(of: [initialized, second], timeout: 2)
        try await pipeline.setRemoteVideoBeauty(nil)
        await pipeline.enqueue(RealtimeVideoFrame(pixelBuffer: input.pixelBuffer,
                                                 presentationTimeStamp: CMTime(value: 125, timescale: 24),
                                                 duration: input.duration))
        await fulfillment(of: [third], timeout: 2)
        let frames = await recorder.values()
        XCTAssertEqual(frames.count, 3)
        let reference = render(frames[1].pixelBuffer)
        for frame in frames {
            assertCompatible(frame)
            XCTAssertTrue(render(frame.pixelBuffer) == reference, "Beauty switching must preserve the shared output color profile")
            XCTAssertEqual(frame.duration, input.duration)
        }
        XCTAssertEqual(render(input.pixelBuffer), originalColors, "The incoming frame must remain immutable")
        XCTAssertNotEqual(originalColors, reference, "This fixture must expose the differing BT.601 and BT.709 interpretation")
        await pipeline.closeBeauty()
    }

    func testStaticInterpolationPreservesDisplayedSDRColorsBeforeBeauty() async throws {
        guard #available(macOS 26.0, *), FrameInterpolationSupport.isSupported else {
            throw XCTSkip("Native interpolation is unavailable")
        }
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            for matrix in [kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVImageBufferYCbCrMatrix_ITU_R_709_2] {
                let input = try makeFrame(format: format)
                setColors(input.pixelBuffer,
                          primaries: matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4
                            ? kCVImageBufferColorPrimaries_SMPTE_C : kCVImageBufferColorPrimaries_ITU_R_709_2,
                          matrix: matrix)
                CVPixelBufferLockBaseAddress(input.pixelBuffer, [])
                let chroma = CVPixelBufferGetBaseAddressOfPlane(input.pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(input.pixelBuffer, 1)
                for row in 0..<120 {
                    for column in stride(from: 0, to: 320, by: 2) {
                        chroma[row * rowBytes + column] = 80
                        chroma[row * rowBytes + column + 1] = 170
                    }
                }
                CVPixelBufferUnlockBaseAddress(input.pixelBuffer, [])
                let before = render(input.pixelBuffer)
                let interpolation = try FrameInterpolationManager(frame: input)
                do {
                    let frames = try await interpolation.process(input, sourceDuration: input.duration)
                    let next = RealtimeVideoFrame(pixelBuffer: input.pixelBuffer,
                                                  presentationTimeStamp: input.presentationTimeStamp + input.duration,
                                                  duration: input.duration)
                    let interpolated = try await interpolation.process(next, sourceDuration: input.duration)
                    XCTAssertEqual(frames.count, 1)
                    XCTAssertEqual(interpolated.count, 2)
                    for (index, copied) in (frames + interpolated).enumerated() {
                        let after = render(copied.pixelBuffer)
                        let center = (120 * 320 + 160) * 4
                        let centerError = zip(before[center..<center+3], after[center..<center+3])
                            .map { abs(Int($0) - Int($1)) }.max() ?? 0
                        let meanError = zip(before, after).reduce(0.0) {
                            $0 + Double(abs(Int($1.0) - Int($1.1)))
                        } / Double(320 * 240 * 3)
                        // Native optical-flow interpolation can alter a few edge pixels on a static field.
                        // A color-interpretation regression instead changes both its center and global mean.
                        XCTAssertLessThanOrEqual(centerError, 3, "Static interpolation changed center colors: \(format), \(matrix), frame \(index)")
                        XCTAssertLessThanOrEqual(meanError, 2, "Static interpolation changed displayed colors: \(format), \(matrix), frame \(index)")
                    }
                    await interpolation.close()
                } catch {
                    await interpolation.close()
                    throw error
                }
            }
        }
    }

    func testInterpolatedSDRFramesCanBePreparedForBeauty() async throws {
        guard #available(macOS 26.0, *), FrameInterpolationSupport.isSupported else {
            throw XCTSkip("Native interpolation is unavailable")
        }
        let input = try makeFrame()
        setColors(input.pixelBuffer, primaries: kCVImageBufferColorPrimaries_SMPTE_C,
                  matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let interpolation = try FrameInterpolationManager(frame: input)
        let converter = BeautyColorConverter()
        defer { converter.close() }
        do {
            let first = try await interpolation.process(input, sourceDuration: input.duration)
            let next = RealtimeVideoFrame(pixelBuffer: input.pixelBuffer,
                                         presentationTimeStamp: input.presentationTimeStamp + input.duration,
                                         duration: input.duration)
            let second = try await interpolation.process(next, sourceDuration: input.duration)
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(second.count, 2)
            for frame in first + second {
                let prepared = try converter.prepare(frame)
                assertCompatible(prepared)
            }
            await interpolation.close()
        } catch {
            await interpolation.close()
            throw error
        }
    }

    private func makeFrame(format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws -> RealtimeVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 240, format,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:],
                                           kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if CVPixelBufferIsPlanar(buffer) {
            for plane in 0..<2 {
                memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 100 : 120,
                       CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        } else {
            memset(CVPixelBufferGetBaseAddress(buffer)!, 100, CVPixelBufferGetBytesPerRow(buffer) * 240)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return RealtimeVideoFrame(pixelBuffer: buffer, presentationTimeStamp: CMTime(value: 123, timescale: 24),
                                  duration: CMTime(value: 1, timescale: 24))
    }

    private func setColors(_ buffer: CVPixelBuffer,
                           primaries: CFString = kCVImageBufferColorPrimaries_ITU_R_709_2,
                           transfer: CFString = kCVImageBufferTransferFunction_ITU_R_709_2,
                           matrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
        for (key, value) in [(kCVImageBufferColorPrimariesKey, primaries),
                              (kCVImageBufferTransferFunctionKey, transfer),
                              (kCVImageBufferYCbCrMatrixKey, matrix)] {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
    }

    private func assertCompatible(_ frame: RealtimeVideoFrame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(frame.pixelBuffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       file: file, line: line)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(frame.pixelBuffer), file: file, line: line)
        for (key, expected) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                                 (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                                 (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            XCTAssertEqual(CVBufferCopyAttachment(frame.pixelBuffer, key, nil) as? String, expected as String,
                           file: file, line: line)
        }
    }

    private func render(_ buffer: CVPixelBuffer) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 320 * 240 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            CIContext().render(CIImage(cvPixelBuffer: buffer), toBitmap: bytes.baseAddress!, rowBytes: 320 * 4,
                               bounds: CGRect(x: 0, y: 0, width: 320, height: 240), format: .BGRA8,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return pixels
    }
}

private actor ColorReferenceBeautyProcessor: BeautyProcessing {
    private let converter = BeautyColorConverter()
    func update(_ options: RealtimeVideoBeautyOptions) {}
    func process(_ frame: RealtimeVideoFrame) async throws -> RealtimeVideoFrame { try converter.prepare(frame) }
    func close() { converter.close() }
}

private actor ResultColorFrameRecorder {
    private var frames: [RealtimeVideoFrame] = []
    func append(_ frame: RealtimeVideoFrame) { frames.append(frame) }
    func values() -> [RealtimeVideoFrame] { frames }
}

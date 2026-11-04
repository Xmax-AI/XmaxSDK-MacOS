import CoreImage
import CoreMedia
import CoreVideo
import XCTest
@testable import XmaxSDK

final class VideoBeautyColorConverterTests: XCTestCase, @unchecked Sendable {
    func testCompatibleAndUntaggedFramesRetainOriginalBuffersAndTiming() throws {
        let converter = VideoBeautyColorConverter()
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
        let converter = VideoBeautyColorConverter()
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

    func testHDRTransferFunctionsFailWithTheirActualValues() throws {
        let converter = VideoBeautyColorConverter()
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
        let converter = VideoBeautyColorConverter()
        let input = try makeFrame()
        setColors(input.pixelBuffer, transfer: kCVImageBufferTransferFunction_sRGB)
        var retained = try (0..<3).map { _ in try converter.prepare(input) }
        let before = render(retained[0].pixelBuffer)
        XCTAssertThrowsError(try converter.prepare(input)) { error in
            guard case VideoBeautyProcessingError.outputBackpressure = error else {
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

    func testInterpolatedSDRFramesCanBePreparedForBeauty() async throws {
        guard #available(macOS 26.0, *), FrameInterpolationSupport.isSupported else {
            throw XCTSkip("Native interpolation is unavailable")
        }
        let input = try makeFrame()
        setColors(input.pixelBuffer, primaries: kCVImageBufferColorPrimaries_SMPTE_C,
                  matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let interpolation = try FrameInterpolationManager(frame: input)
        let converter = VideoBeautyColorConverter()
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

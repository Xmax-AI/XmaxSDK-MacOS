@preconcurrency import AgoraRtcKit
import CoreMedia
import CoreVideo
import os
import XCTest
@testable import XmaxSDK

final class RtcRemoteVideoSinkTests: XCTestCase, @unchecked Sendable {
    func testSubscriptionLookupPrecedesPixelBufferValidation() {
        let lookup = expectation(description: "Subscription checked even for a frame without a pixel buffer")
        lookup.assertForOverFulfill = true
        let sink = RtcRemoteVideoSink { _, _ in
            lookup.fulfill()
            return nil
        }
        let frame = AgoraOutputVideoFrame()
        frame.pixelBuffer = nil

        XCTAssertTrue(sink.onRenderVideoFrame(frame, uid: 42, channelId: "test"))
        wait(for: [lookup], timeout: 1)
    }

    func testRetiredSubscriptionDoesNotReceiveOrRedirectTheInFlightFrame() throws {
        let original = RtcRemoteVideoSink.Subscription { _ in XCTFail("Retired listener received the frame") }
        let received = expectation(description: "Replacement receives the next frame")
        received.assertForOverFulfill = true
        let replacement = RtcRemoteVideoSink.Subscription { frame in
            XCTAssertEqual(frame.presentationTimeStamp, CMTime(value: 1235, timescale: 1000))
            received.fulfill()
        }
        let frame = try makeFrame()

        for latest in [nil, replacement] {
            let lookups = OSAllocatedUnfairLock(initialState: 0)
            let sink = RtcRemoteVideoSink { _, _ in
                lookups.withLock { count in
                    count += 1
                    return count == 1 ? original : latest
                }
            }
            frame.renderTimeMs = 1234
            XCTAssertTrue(sink.onRenderVideoFrame(frame, uid: 42, channelId: "test"))
            XCTAssertEqual(lookups.withLock { $0 }, 2)
            if latest != nil {
                frame.renderTimeMs = 1235
                XCTAssertTrue(sink.onRenderVideoFrame(frame, uid: 42, channelId: "test"))
                XCTAssertEqual(lookups.withLock { $0 }, 4)
            }
        }
        wait(for: [received], timeout: 1)
    }

    func testUntaggedFramesUseRTCDefaultColorsWithoutChangingPixelsOrRange() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            let source = try makeFrame(format: format)
            source.colorSpace = nil
            let received = expectation(description: "Decoded frame delivered")
            let sink = makeSink { frame in
                XCTAssertEqual(frame.presentationTimeStamp, CMTime(value: 1234, timescale: 1000))
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(frame.pixelBuffer), format)
                self.assertColor(frame.pixelBuffer)
                self.assertPixels(frame.pixelBuffer)

                var description: CMVideoFormatDescription?
                XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil,
                                                                          imageBuffer: frame.pixelBuffer,
                                                                          formatDescriptionOut: &description), noErr)
                if let description, let extensions = CMFormatDescriptionGetExtensions(description) {
                    let values = extensions as NSDictionary
                    XCTAssertEqual(values[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
                                   kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
                    XCTAssertEqual(values[kCMFormatDescriptionExtension_TransferFunction] as? String,
                                   kCVImageBufferTransferFunction_ITU_R_709_2 as String)
                    XCTAssertEqual(values[kCMFormatDescriptionExtension_YCbCrMatrix] as? String,
                                   kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
                } else {
                    XCTFail("Display format description must contain color information")
                }
                received.fulfill()
            }
            XCTAssertTrue(sink.onRenderVideoFrame(source, uid: 42, channelId: "test"))
            wait(for: [received], timeout: 1)
            XCTAssertNil(CVBufferCopyAttachment(try XCTUnwrap(source.pixelBuffer), kCVImageBufferYCbCrMatrixKey, nil))
        }
    }

    func testRTCMetadataSuppliesMissingSDColorAttachments() throws {
        let source = try makeFrame()
        let color = AgoraColorSpace()
        color.primaryID = .IDSMPTE170M
        color.transferID = .IDSMPTE170M
        color.matrixID = .IDSMPTE170M
        source.colorSpace = color
        let received = expectation(description: "SD frame delivered")
        let sink = makeSink { frame in
            self.assertColor(frame.pixelBuffer, primaries: kCVImageBufferColorPrimaries_SMPTE_C,
                             matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
            received.fulfill()
        }
        XCTAssertTrue(sink.onRenderVideoFrame(source, uid: 42, channelId: "test"))
        wait(for: [received], timeout: 1)
    }

    func testExplicitBufferColorAttachmentsArePreserved() throws {
        let source = try makeFrame()
        source.colorSpace = AgoraColorSpace()
        let pixels = try XCTUnwrap(source.pixelBuffer)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        let received = expectation(description: "Tagged frame delivered")
        let sink = makeSink { frame in
            self.assertColor(frame.pixelBuffer, primaries: kCVImageBufferColorPrimaries_SMPTE_C,
                             transfer: kCVImageBufferTransferFunction_sRGB,
                             matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
            self.assertPixels(frame.pixelBuffer)
            received.fulfill()
        }
        XCTAssertTrue(sink.onRenderVideoFrame(source, uid: 42, channelId: "test"))
        wait(for: [received], timeout: 1)
    }

    func testHDRMetadataIsNotReplacedWithSDRDefaults() throws {
        for (transfer, expected) in [(AgoraColorTransferID.IDSMPTEST2084, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
                                     (.IDARIB_STD_B67, kCVImageBufferTransferFunction_ITU_R_2100_HLG)] {
            let source = try makeFrame()
            let color = AgoraColorSpace()
            color.primaryID = .IDBT2020
            color.transferID = transfer
            color.matrixID = .IDBT2020_NCL
            source.colorSpace = color
            let received = expectation(description: "HDR frame delivered")
            let sink = makeSink { frame in
                self.assertColor(frame.pixelBuffer, primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                 transfer: expected, matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
                received.fulfill()
            }
            XCTAssertTrue(sink.onRenderVideoFrame(source, uid: 42, channelId: "test"))
            wait(for: [received], timeout: 1)
        }
    }

    func testPooledBuffersDoNotRetainPreviousFramesColorOrOtherAttachments() throws {
        let tagged = try makeFrame()
        let pixels = try XCTUnwrap(tagged.pixelBuffer)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                              .shouldPropagate)
        CVBufferSetAttachment(pixels, "test.previous-frame" as CFString, "old" as CFString, .shouldPropagate)
        let untagged = try makeFrame()
        untagged.renderTimeMs = 1235
        let received = expectation(description: "Both frames delivered")
        received.expectedFulfillmentCount = 2
        let sink = makeSink { frame in
            if frame.presentationTimeStamp == CMTime(value: 1234, timescale: 1000) {
                self.assertColor(frame.pixelBuffer, transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
            } else {
                self.assertColor(frame.pixelBuffer)
                XCTAssertNil(CVBufferCopyAttachment(frame.pixelBuffer, "test.previous-frame" as CFString, nil))
            }
            received.fulfill()
        }
        XCTAssertTrue(sink.onRenderVideoFrame(tagged, uid: 42, channelId: "test"))
        XCTAssertTrue(sink.onRenderVideoFrame(untagged, uid: 42, channelId: "test"))
        wait(for: [received], timeout: 1)
    }

    private func makeSink(_ listener: @escaping RtcRemoteVideoFrameListener) -> RtcRemoteVideoSink {
        let subscription = RtcRemoteVideoSink.Subscription(listener)
        return RtcRemoteVideoSink { uid, channel in
            XCTAssertEqual(uid, 42)
            XCTAssertEqual(channel, "test")
            return subscription
        }
    }

    private func makeFrame(format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws -> AgoraOutputVideoFrame {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                          &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, plane == 0 ? 100 : 120,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = AgoraOutputVideoFrame()
        frame.pixelBuffer = buffer
        frame.renderTimeMs = 1234
        return frame
    }

    private func assertPixels(_ buffer: CVPixelBuffer, file: StaticString = #filePath, line: UInt = #line) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        for plane in 0..<2 {
            let pixels = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                for column in 0..<4 {
                    XCTAssertEqual(pixels[row * stride + column], plane == 0 ? 100 : 120, file: file, line: line)
                }
            }
        }
    }

    private func assertColor(_ buffer: CVPixelBuffer,
                             primaries: CFString = kCVImageBufferColorPrimaries_ITU_R_709_2,
                             transfer: CFString = kCVImageBufferTransferFunction_ITU_R_709_2,
                             matrix: CFString = kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                             file: StaticString = #filePath, line: UInt = #line) {
        for (key, expected) in [(kCVImageBufferColorPrimariesKey, primaries),
                                (kCVImageBufferTransferFunctionKey, transfer),
                                (kCVImageBufferYCbCrMatrixKey, matrix)] {
            XCTAssertEqual(CVBufferCopyAttachment(buffer, key, nil) as? String, expected as String, file: file, line: line)
        }
    }
}

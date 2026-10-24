//
//  ExternalVideoControllerTests.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import CoreVideo
import XCTest
@testable import XmaxSDK

@MainActor
final class ExternalVideoControllerTests: XCTestCase {

    func testDemandTimestampsAndBufferOwnershipAcrossBindings() async throws {
        let recorder = ExternalInputRecorder()
        let controller = makeController(recorder)
        let source = ExternalSourceStub()
        _ = try await controller.create(source: source, videoFormat: nil)
        let sink = try XCTUnwrap(source.sink)
        XCTAssertEqual(sink.videoFormat, RealtimeVideoFormat(width: 4, height: 4, fps: 30))
        XCTAssertFalse(sink.isRequestingFrames)
        let buffer = try Self.makeBuffer()
        sink.pushVideo(buffer, timestampUs: 100)
        XCTAssertTrue(recorder.frames.isEmpty)

        recorder.requesting = true
        XCTAssertTrue(sink.isRequestingFrames)
        Self.fill(buffer, with: 7)
        sink.pushVideo(buffer, timestampUs: 0)
        Self.fill(buffer, with: 9)
        XCTAssertEqual(recorder.frames.first?.planes.first?.data.first, 7)
        sink.pushVideo(buffer, timestampUs: 0)
        sink.pushVideo(buffer, timestampUs: -1)
        XCTAssertEqual(recorder.frames.count, 1)
        recorder.requesting = false
        sink.pushVideo(buffer, timestampUs: 100)
        recorder.requesting = true
        sink.pushVideo(buffer, timestampUs: 1)
        XCTAssertEqual(recorder.frames.map(\.timestampUs), [0, 1])
        XCTAssertEqual(recorder.frames.first?.format.pixelFormat, .bgra)
        XCTAssertEqual(recorder.frames.first?.rotation, .rotation0)

        await controller.stop()
        await controller.stop()
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(sink.isRequestingFrames)
        _ = try await controller.create(source: ExternalSourceStub(), videoFormat: nil)
        sink.pushVideo(buffer, timestampUs: 2)
        sink.reportError(XmaxError(code: .mediaError, message: "late"))
        XCTAssertEqual(recorder.frames.count, 2)
        XCTAssertTrue(recorder.errors.isEmpty)
        await controller.stop()
    }

    func testNV12PlanesAreCopiedWithTheirRowStrides() async throws {
        let recorder = ExternalInputRecorder(requesting: true)
        let controller = makeController(recorder)
        let source = ExternalSourceStub()
        _ = try await controller.create(source: source, videoFormat: nil)
        let buffer = try Self.makeBuffer(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(buffer, [])
        for index in 0..<2 {
            let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, index) * CVPixelBufferGetHeightOfPlane(buffer, index)
            CVPixelBufferGetBaseAddressOfPlane(buffer, index)?.initializeMemory(
                as: UInt8.self, repeating: index == 0 ? 16 : 128, count: count
            )
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        source.sink?.pushVideo(buffer, timestampUs: 1)
        let frame = try XCTUnwrap(recorder.frames.first)
        XCTAssertEqual(frame.format.pixelFormat, .nv12)
        XCTAssertEqual(frame.planes.count, 2)
        XCTAssertEqual(frame.planes[0].data.first, 16)
        XCTAssertEqual(frame.planes[1].data.first, 128)
        XCTAssertEqual(frame.planes[0].stride, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        XCTAssertEqual(frame.planes[1].data.count, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 2)
        XCTAssertTrue(recorder.errors.isEmpty)
        await controller.stop()
    }

    func testInvalidPixelsFailOnceAndDisableTheBinding() async throws {
        for buffer in [
            try Self.makeBuffer(width: 8),
            try Self.makeBuffer(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ] {
            let recorder = ExternalInputRecorder(requesting: true)
            let controller = makeController(recorder)
            let source = ExternalSourceStub()
            _ = try await controller.create(source: source, videoFormat: nil)
            let sink = try XCTUnwrap(source.sink)
            sink.pushVideo(buffer, timestampUs: 1)
            sink.pushVideo(buffer, timestampUs: 2)
            sink.reportError(XmaxError(code: .mediaError, message: "duplicate failure"))
            XCTAssertTrue(recorder.frames.isEmpty)
            XCTAssertEqual(recorder.errors.count, 1)
            XCTAssertEqual(recorder.errors.first?.code, .mediaError)
            XCTAssertFalse(sink.isRequestingFrames)
            await controller.stop()
        }
    }

    func testPreviewDelegatesAndStopPreservesCallerCapture() async throws {
        let recorder = ExternalInputRecorder()
        let controller = makeController(recorder)
        let source = ExternalSourceStub()
        let stream = try await controller.create(source: source, videoFormat: nil)
        let track = try XCTUnwrap(stream.videoTrack)
        let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: track))
        let container = NSView()
        try binding.attach(to: container, contentMode: .fill)
        XCTAssertTrue(source.previewContainer === container)
        XCTAssertEqual(source.contentMode, .fill)
        await controller.stop()
        XCTAssertEqual(source.detachments, 1)
        XCTAssertTrue(source.captureRunning)
        XCTAssertNil(VideoRenderRegistry.binding(for: track))
        XCTAssertNil(controller.currentTrack)
    }

    func testFailedStartRollsBackAndAllowsRetry() async throws {
        let recorder = ExternalInputRecorder(requesting: true)
        let controller = makeController(recorder)
        let source = ExternalSourceStub()
        source.startError = XmaxError(code: .mediaError, message: "Binding failed")
        do {
            _ = try await controller.create(source: source, videoFormat: nil)
            XCTFail("Expected binding failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(source.lastSink?.isRequestingFrames ?? true)
        XCTAssertNil(controller.currentTrack)
        _ = try await controller.create(source: ExternalSourceStub(), videoFormat: nil)
        await controller.stop()
    }

    func testCancelledStartRetainsCancellationSemantics() async throws {
        let controller = makeController(ExternalInputRecorder())
        let source = ExternalSourceStub()
        source.startError = CancellationError()
        do {
            _ = try await controller.create(source: source, videoFormat: nil)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        XCTAssertNil(controller.currentTrack)
        XCTAssertEqual(source.stops, 1)
    }

    func testModelFormatValidationPrecedesSourceBinding() async throws {
        let rtc = RtcManagingStub()
        let controller = makeController(ExternalInputRecorder(), rtc: rtc, media: MediaService())
        let source = ExternalSourceStub(videoFormat: RealtimeVideoFormat(width: 1080, height: 1920, fps: 60))
        for invalid in [
            RealtimeVideoFormat(width: 1024, height: 1920, fps: 0),
            RealtimeVideoFormat(width: 1024, height: 1920, fps: 30, maximumBitrate: -1)
        ] {
            do {
                _ = try await controller.create(source: source, videoFormat: invalid)
                XCTFail("Expected invalid explicit format")
            } catch {
                XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
            }
        }
        XCTAssertNil(source.sink)
        XCTAssertTrue(rtc.calls.isEmpty)
        let format = RealtimeVideoFormat(
            width: 1024, height: 1920, fps: 24,
            minimumBitrate: 800, maximumBitrate: 2000, encoderPreference: .maintainQuality
        )
        let stream = try await controller.create(source: source, videoFormat: format)
        XCTAssertEqual(stream.videoTrack?.videoFormat, format)
        XCTAssertEqual(source.sink?.videoFormat, format)
        XCTAssertEqual(rtc.calls, [.useExternalVideoSource])
        await controller.stop()
    }

    func testExternalDimensionsAreResolvedWithoutCameraBucketRestrictions() async throws {
        for (input, expected) in [
            (CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1920)),
            (CGSize(width: 200, height: 200), CGSize(width: 448, height: 448)),
            (CGSize(width: 3840, height: 2160), CGSize(width: 1920, height: 1080))
        ] {
            let controller = makeController(ExternalInputRecorder(), media: MediaService())
            let source = ExternalSourceStub(videoFormat: RealtimeVideoFormat(
                width: Int(input.width), height: Int(input.height), fps: 30
            ))
            let stream = try await controller.create(source: source, videoFormat: nil)
            XCTAssertEqual(source.sink?.videoFormat.size, expected)
            XCTAssertEqual(stream.videoTrack?.videoFormat?.size, expected)
            await controller.stop()
        }
    }

    func testDefaultPreviewMethodsAndBackgroundSubmission() async throws {
        let recorder = ExternalInputRecorder(requesting: true)
        let controller = makeController(recorder)
        let source = VideoOnlySource()
        let stream = try await controller.create(source: source, videoFormat: nil)
        let track = try XCTUnwrap(stream.videoTrack)
        let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: track))
        try binding.attach(to: NSView(), contentMode: .fit)
        let sink = try XCTUnwrap(source.sink)
        try await Self.submitInBackground(to: sink)
        XCTAssertEqual(recorder.frames.count, 1)
        await controller.stop()
    }

    private func makeController(
        _ recorder: ExternalInputRecorder,
        rtc: RtcManagingStub = RtcManagingStub(),
        media: any MediaServicing = MediaServicingStub(resolvedSize: CGSize(width: 4, height: 4))
    ) -> ExternalVideoController {
        ExternalVideoController(
            rtcManager: rtc, mediaService: media,
            requestingFrames: { recorder.requesting },
            videoFrameListener: { recorder.record($0) },
            errorListener: { recorder.record($0) }
        )
    }

    nonisolated private static func submitInBackground(to sink: any RealtimeExternalFrameSink) async throws {
        let submission = Task<Void, any Error>.detached {
            let buffer = try makeBuffer()
            sink.pushVideo(buffer, timestampUs: 1)
        }
        try await submission.value
    }

    nonisolated static func makeBuffer(
        width: Int = 4,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, 4, pixelFormat, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XmaxError(code: .internalError, message: "Test pixel buffer allocation failed")
        }
        return buffer
    }

    nonisolated private static func fill(_ buffer: CVPixelBuffer, with byte: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        CVPixelBufferGetBaseAddress(buffer)?.initializeMemory(
            as: UInt8.self, repeating: byte, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        )
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }
}

@MainActor
final class ExternalSourceStub: RealtimeExternalVideoSource {

    /// Source configuration
    let videoFormat: RealtimeVideoFormat
    var startError: (any Error)?
    var startHandler: (@MainActor () async throws -> Void)?
    let captureRunning = true

    /// Binding and preview state
    var sink: (any RealtimeExternalFrameSink)?
    var lastSink: (any RealtimeExternalFrameSink)?
    var stops = 0
    var previewContainer: NSView?
    var contentMode: VideoContentMode?
    var detachments = 0

    init(videoFormat: RealtimeVideoFormat = RealtimeVideoFormat(width: 4, height: 4, fps: 60)) {
        self.videoFormat = videoFormat
    }

    func start(sink: any RealtimeExternalFrameSink) async throws {
        self.sink = sink
        lastSink = sink
        if let startError { throw startError }
        try await startHandler?()
    }

    func stop() async {
        sink = nil
        stops += 1
    }

    func attachPreview(to container: NSView, contentMode: VideoContentMode) {
        previewContainer = container
        self.contentMode = contentMode
    }

    func detachPreview(from container: NSView) {
        XCTAssertTrue(previewContainer === container)
        previewContainer = nil
        detachments += 1
    }
}

private final class ExternalInputRecorder: @unchecked Sendable {

    /// Concurrent test state
    private let lock = NSLock()
    private var storedRequesting: Bool
    private var storedFrames: [VideoFrame] = []
    private var storedErrors: [XmaxError] = []

    init(requesting: Bool = false) { storedRequesting = requesting }

    var requesting: Bool {
        get { lock.withLock { storedRequesting } }
        set { lock.withLock { storedRequesting = newValue } }
    }

    var frames: [VideoFrame] { lock.withLock { storedFrames } }
    var errors: [XmaxError] { lock.withLock { storedErrors } }

    func record(_ frame: VideoFrame) { lock.withLock { storedFrames.append(frame) } }
    func record(_ error: XmaxError) { lock.withLock { storedErrors.append(error) } }
}

@MainActor
private final class VideoOnlySource: RealtimeExternalVideoSource {
    let videoFormat = RealtimeVideoFormat(width: 4, height: 4, fps: 30)
    var sink: (any RealtimeExternalFrameSink)?

    func start(sink: any RealtimeExternalFrameSink) async throws { self.sink = sink }
    func stop() async { sink = nil }
}

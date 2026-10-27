//
//  ExternalVideoControllerTests.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreVideo
import XCTest
@testable import XmaxSDK

@MainActor
final class ExternalVideoControllerTests: XCTestCase {
    func testAudioSourceOwnsCustomTrackWithoutMicrophoneCapture() async throws {
        let rtc = RtcManagingStub()
        let controller = makeController(rtc)
        let source = RealtimeExternalVideoSourceStub(hasAudio: true)
        _ = try await controller.create(source: source)
        XCTAssertTrue(controller.hasAudio)
        XCTAssertEqual(rtc.calls, [.useExternalVideoSource, .startExternalAudioSource])
        await controller.stop()
        await controller.stop()
        XCTAssertFalse(controller.hasAudio)
        XCTAssertEqual(rtc.calls.filter { $0 == .stopExternalAudioSource }.count, 1)
        XCTAssertFalse(rtc.calls.contains(.startAudioCapture))
    }

    func testFailedAudioSourceStartupReleasesTrackAndAllowsSilentRetry() async throws {
        let rtc = RtcManagingStub()
        let controller = makeController(rtc)
        let source = RealtimeExternalVideoSourceStub(hasAudio: true)
        source.startHandler = { throw XmaxError(code: .mediaError, message: "failed") }
        do {
            _ = try await controller.create(source: source)
            XCTFail("Expected startup failure")
        } catch {}
        XCTAssertFalse(controller.hasAudio)
        XCTAssertNil(controller.currentTrack)
        XCTAssertEqual(rtc.calls.filter { $0 == .stopExternalAudioSource }.count, 1)
        _ = try await controller.create(source: RealtimeExternalVideoSourceStub())
        XCTAssertFalse(controller.hasAudio)
        await controller.stop()
        XCTAssertEqual(rtc.calls.filter { $0 == .stopExternalAudioSource }.count, 1)
    }

    func testResolvesSizePreservesSourceFPSAndEncodingWithoutMicrophone() async throws {
        let rtc = RtcManagingStub()
        let controller = makeController(rtc)
        let format = RealtimeVideoFormat(width: 3840, height: 2160, fps: 60, minimumBitrate: 600, maximumBitrate: 3000)
        let source = RealtimeExternalVideoSourceStub(videoFormat: format)
        let stream = try await controller.create(source: source)
        let resolved = try XCTUnwrap(source.sink?.videoFormat)
        XCTAssertEqual(resolved.fps, 60)
        XCTAssertEqual(resolved.minimumBitrate, 600)
        XCTAssertEqual(resolved.maximumBitrate, 3000)
        XCTAssertLessThanOrEqual(resolved.width * resolved.height, RealtimeModel.x2_1.maximumInputPixels)
        XCTAssertEqual(resolved.width % 4, 0)
        XCTAssertEqual(resolved.height % 4, 0)
        XCTAssertEqual(stream.videoTrack?.videoFormat, resolved)
        XCTAssertEqual(rtc.calls, [.useExternalVideoSource])
        XCTAssertNotNil(VideoRenderRegistry.binding(for: try XCTUnwrap(stream.videoTrack)))
        await controller.stop()
    }

    func testAcceptsNonCameraBucketAndStopInvalidatesOldSink() async throws {
        let controller = makeController()
        let source = RealtimeExternalVideoSourceStub()
        let stream = try await controller.create(source: source)
        let oldSink = try XCTUnwrap(source.sink)
        XCTAssertEqual(oldSink.videoFormat, source.videoFormat)
        await controller.stop()
        await controller.stop()
        XCTAssertFalse(oldSink.isRequestingFrames)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertNil(controller.currentTrack)
        XCTAssertNil(VideoRenderRegistry.binding(for: try XCTUnwrap(stream.videoTrack)))
        _ = try await controller.create(source: source)
        XCTAssertTrue(source.sink?.isRequestingFrames == true)
        XCTAssertFalse(oldSink.isRequestingFrames)
        await controller.stop()
    }

    func testStartFailureRollsBackAndAllowsRetry() async throws {
        let controller = makeController()
        let source = RealtimeExternalVideoSourceStub()
        source.startHandler = { throw XmaxError(code: .mediaError, message: "start failed") }
        do {
            _ = try await controller.create(source: source)
            XCTFail("Expected startup failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertNil(controller.currentTrack)
        XCTAssertNil(source.sink)
        source.startHandler = nil
        _ = try await controller.create(source: source)
        await controller.stop()
    }

    func testCancellationDuringStartUnbindsSource() async throws {
        let controller = makeController()
        let source = RealtimeExternalVideoSourceStub()
        source.startHandler = { try await Task.sleep(nanoseconds: 60000000000) }
        let task = Task { try await controller.create(source: source) }
        while source.sink == nil { await Task.yield() }
        let sink = try XCTUnwrap(source.sink)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        XCTAssertFalse(sink.isRequestingFrames)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertNil(controller.currentTrack)
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

    func testSDKPreviewReceivesExternalFramesBeforeConnection() async throws {
        let controller = makeController()
        let source = RealtimeExternalVideoSourceStub(
            videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30)
        )
        let local = try await controller.create(source: source)
        let view = XmaxRealtimeVideoView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let displayed = expectation(description: "SDK preview receives disconnected external input")
        view.frameDisplayHandler = { displayed.fulfill() }
        view.track = local.videoTrack
        let binding = try XCTUnwrap(VideoRenderRegistry.binding(for: try XCTUnwrap(local.videoTrack)))
        try binding.attach(to: view, contentMode: .fit)
        let sink = try XCTUnwrap(source.sink)
        XCTAssertTrue(sink.isRequestingFrames)
        sink.pushVideo(try Self.makeBuffer(), timestamp: .zero)
        await fulfillment(of: [displayed], timeout: 2)
        await controller.stop()
        XCTAssertFalse(sink.isRequestingFrames)
        view.track = nil
    }

    private func makeController(_ rtc: RtcManagingStub = RtcManagingStub()) -> ExternalVideoController {
        ExternalVideoController(
            rtcManager: rtc,
            mediaService: MediaService(),
            videoFrameListener: { _ in },
            errorListener: { _ in }
        )
    }
}

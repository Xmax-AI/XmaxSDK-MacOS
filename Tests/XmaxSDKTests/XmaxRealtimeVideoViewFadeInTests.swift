//
//  XmaxRealtimeVideoViewFadeInTests.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import CoreMedia
import CoreVideo
import QuartzCore
import XCTest
@testable import XmaxSDK

@MainActor
final class XmaxRealtimeVideoViewFadeInTests: XCTestCase {
    func testFadeIsDisabledByDefaultInAppKitAndSwiftUI() throws {
        let view = XmaxRealtimeVideoView()
        XCTAssertEqual(view.fadeInDuration, 0)
        XCTAssertEqual(XmaxRealtimeVideo(track: nil).fadeInDuration, 0)
        XCTAssertEqual(XmaxRealtimeVideo(track: nil, fadeInDuration: 0.3).fadeInDuration, 0.3)

        view.displayRemoteVideoFrame(try frame(), contentMode: .fit)

        XCTAssertNil(fade(in: view))
        XCTAssertEqual(view.alphaValue, 1)
    }

    func testFirstRemoteFrameFadesOnceAndPreservesEveryFrameNotification() throws {
        let track = RealtimeVideoTrack(id: "remote")
        let view = XmaxRealtimeVideoView(track: track, fadeInDuration: 0.6)
        var notifications = 0
        view.frameDisplayHandler = { notifications += 1 }
        XCTAssertNil(fade(in: view))

        view.displayRemoteVideoFrame(try frame(), contentMode: .fit)

        try assertFade(in: view, duration: 0.6)
        XCTAssertEqual(notifications, 1)
        view.fadeInDuration = 0.9
        view.track = track
        view.videoContentMode = .fill
        view.isMirrored = true
        view.displayRemoteVideoFrame(try frame(width: 8, height: 4), contentMode: .fill)

        try assertFade(in: view, duration: 0.6)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(view.alphaValue, 1)
    }

    func testTrackReplacementAndClearingCancelThePreviousFade() throws {
        let view = XmaxRealtimeVideoView(
            track: RealtimeVideoTrack(id: "first"), fadeInDuration: 0.3
        )
        view.displayRemoteVideoFrame(try frame(), contentMode: .fit)
        try assertFade(in: view, duration: 0.3)

        view.fadeInDuration = 0.8
        view.track = RealtimeVideoTrack(id: "second")
        XCTAssertNil(fade(in: view))
        view.displayRemoteVideoFrame(try frame(), contentMode: .fit)
        try assertFade(in: view, duration: 0.8)

        view.track = nil
        XCTAssertNil(fade(in: view))
    }

    func testInvalidDurationsDoNotAnimateOrSuppressFrameNotifications() throws {
        for duration in [0, -0.3, Double.nan, .infinity, -.infinity] {
            let view = XmaxRealtimeVideoView(fadeInDuration: duration)
            var notifications = 0
            view.frameDisplayHandler = { notifications += 1 }

            view.displayRemoteVideoFrame(try frame(), contentMode: .fit)

            XCTAssertNil(fade(in: view))
            XCTAssertEqual(view.alphaValue, 1)
            XCTAssertEqual(notifications, 1)
        }
    }

    func testClearedDecodedPreviewFadesAgainAfterRebinding() throws {
        let view = XmaxRealtimeVideoView(fadeInDuration: 0.3)
        let local = try VideoFrame(
            format: VideoFormat(width: 4, height: 4, pixelFormat: .bgra),
            timestampUs: 0,
            planes: [VideoFramePlane(data: Data(repeating: 128, count: 64), stride: 16)]
        )
        view.displayDecodedVideoFrame(local, contentMode: .fit)
        try assertFade(in: view, duration: 0.3)

        view.clearDecodedVideoPreview()
        XCTAssertNil(fade(in: view))
        view.fadeInDuration = 0.7
        view.displayDecodedVideoFrame(local, contentMode: .fit)
        try assertFade(in: view, duration: 0.7)
    }

    func testNativePreviewFadesOnceWithoutWaitingForDecodedFrames() throws {
        let view = XmaxRealtimeVideoView(fadeInDuration: 0.3)
        let presenter = RtcCameraPreviewPresenter(rtcManager: RtcManagingStub(), mirrored: false)

        try presenter.attach(to: view, contentMode: .fit)

        try assertFade(in: view, duration: 0.3)
        view.fadeInDuration = 0.7
        try presenter.setMirrored(true)
        try assertFade(in: view, duration: 0.3)

        try presenter.clear()
        XCTAssertNil(fade(in: view))
        try presenter.attach(to: view, contentMode: .fit)
        try assertFade(in: view, duration: 0.7)
        try presenter.clear()
    }

    func testSingleTrackFadeDoesNotAddASecondAnimationToDualViews() throws {
        let view = XmaxRealtimeDualVideoView(remoteTrack: RealtimeVideoTrack(id: "remote"))
        let remote = try XCTUnwrap(view.subviews.last as? XmaxRealtimeVideoView)
        XCTAssertEqual(remote.fadeInDuration, 0)

        remote.displayRemoteVideoFrame(try frame(), contentMode: .fit)

        XCTAssertNil(fade(in: remote))
        let dualFade = try XCTUnwrap(remote.layer?.animation(forKey: "remoteVideoFadeIn"))
        XCTAssertEqual(dualFade.duration, 0.3)
        XCTAssertFalse(remote.isHidden)
    }

    private func fade(in view: XmaxRealtimeVideoView) -> CABasicAnimation? {
        view.layer?.animation(forKey: "videoFadeIn") as? CABasicAnimation
    }

    private func assertFade(in view: XmaxRealtimeVideoView, duration: TimeInterval) throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNil(fade(in: view))
        } else {
            let animation = try XCTUnwrap(fade(in: view))
            XCTAssertEqual(animation.keyPath, "opacity")
            XCTAssertEqual(animation.duration, duration)
            XCTAssertEqual(animation.fromValue as? Double, 0)
            XCTAssertEqual(animation.toValue as? Double, 1)
        }
    }

    private func frame(width: Int = 4, height: Int = 4) throws -> RealtimeVideoFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return RealtimeVideoFrame(
            pixelBuffer: try XCTUnwrap(buffer), presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 30)
        )
    }
}

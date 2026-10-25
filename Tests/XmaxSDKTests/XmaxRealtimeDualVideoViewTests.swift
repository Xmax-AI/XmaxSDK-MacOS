import AppKit
import QuartzCore
import XCTest
@testable import XmaxSDK

@MainActor
final class XmaxRealtimeDualVideoViewTests: XCTestCase {
    func testFirstFrameFadesInRemoteVideoWhileRetainingLocalPreview() throws {
        XCTAssertEqual(XmaxRealtimeDualVideoView().remoteVideoFadeInDuration, 0.3)
        let localTrack = RealtimeVideoTrack(id: "local")
        let remoteTrack = RealtimeVideoTrack(id: "remote")
        let view = XmaxRealtimeDualVideoView(
            localTrack: localTrack, remoteTrack: remoteTrack, remoteVideoFadeInDuration: 0.75
        )
        let local = try XCTUnwrap(view.subviews.first as? XmaxRealtimeVideoView)
        let remote = try XCTUnwrap(view.subviews.last as? XmaxRealtimeVideoView)
        XCTAssertTrue(remote.isHidden)
        XCTAssertEqual(remote.alphaValue, 0)
        XCTAssertTrue(opacityAnimations(in: remote).isEmpty)
        XCTAssertTrue(local.track === localTrack)

        let firstFrame = try XCTUnwrap(remote.frameDisplayHandler)
        firstFrame()

        XCTAssertFalse(remote.isHidden)
        XCTAssertEqual(remote.alphaValue, 1)
        XCTAssertTrue(local.track === localTrack)
        XCTAssertFalse(local.isHidden)
        let animation = try XCTUnwrap(opacityAnimations(in: remote).first)
        XCTAssertEqual(animation.duration, 0.75)
        view.remoteVideoFadeInDuration = 0
        XCTAssertEqual(opacityAnimations(in: remote).first?.duration, 0.75,
                       "Changing the duration must not alter an active fade")
        XCTAssertNil(remote.frameDisplayHandler)

        view.remoteTrack = nil
        XCTAssertTrue(remote.isHidden)
        XCTAssertEqual(remote.alphaValue, 0)
        XCTAssertTrue(opacityAnimations(in: remote).isEmpty)
        XCTAssertTrue(local.track === localTrack)
    }

    func testZeroNegativeAndNonfiniteDurationsShowFirstFrameImmediately() throws {
        for duration in [0, -0.2, Double.infinity, -Double.infinity, Double.nan] {
            let view = XmaxRealtimeDualVideoView(
                remoteTrack: RealtimeVideoTrack(id: "remote"), remoteVideoFadeInDuration: duration
            )
            let remote = try XCTUnwrap(view.subviews.last as? XmaxRealtimeVideoView)
            let firstFrame = try XCTUnwrap(remote.frameDisplayHandler)
            XCTAssertTrue(remote.isHidden)

            firstFrame()

            XCTAssertFalse(remote.isHidden)
            XCTAssertEqual(remote.alphaValue, 1)
            XCTAssertTrue(opacityAnimations(in: remote).isEmpty)
            view.remoteTrack = nil
        }
    }

    func testReplacementAndClearingRejectStaleFirstFrameCallbacksAndCancelFades() throws {
        let first = RealtimeVideoTrack(id: "first")
        let second = RealtimeVideoTrack(id: "second")
        let view = XmaxRealtimeDualVideoView(remoteTrack: first)
        let remote = try XCTUnwrap(view.subviews.last as? XmaxRealtimeVideoView)
        let staleFirstFrame = try XCTUnwrap(remote.frameDisplayHandler)
        staleFirstFrame()
        XCTAssertFalse(opacityAnimations(in: remote).isEmpty)

        view.remoteTrack = second
        XCTAssertTrue(remote.isHidden)
        XCTAssertTrue(opacityAnimations(in: remote).isEmpty)
        staleFirstFrame()
        XCTAssertTrue(remote.isHidden, "An old track must not reveal its replacement before its first frame")
        XCTAssertEqual(remote.alphaValue, 0)
        XCTAssertTrue(remote.track === second)

        view.remoteVideoFadeInDuration = 0.6
        let secondFrame = try XCTUnwrap(remote.frameDisplayHandler)
        secondFrame()
        XCTAssertFalse(remote.isHidden)
        XCTAssertEqual(opacityAnimations(in: remote).first?.duration, 0.6)
        view.remoteTrack = nil
        secondFrame()
        XCTAssertTrue(remote.isHidden)
        XCTAssertEqual(remote.alphaValue, 0)
        XCTAssertTrue(opacityAnimations(in: remote).isEmpty)
        XCTAssertNil(remote.track)
    }

    private func opacityAnimations(in view: NSView) -> [CABasicAnimation] {
        (view.layer?.animationKeys() ?? []).compactMap { key in
            guard let animation = view.layer?.animation(forKey: key) as? CABasicAnimation,
                  animation.keyPath == "opacity" else { return nil }
            return animation
        }
    }
}

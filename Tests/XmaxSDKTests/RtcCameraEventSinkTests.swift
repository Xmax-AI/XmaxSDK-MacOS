@preconcurrency import AgoraRtcKit
import XCTest
@testable import XmaxSDK

final class RtcCameraEventSinkTests: XCTestCase, @unchecked Sendable {
    func testCaptureCanBecomeReadyWhileTheNativePreviewIsHidden() async {
        let sink = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit()
        let ready = expectation(description: "Capture readiness does not wait for a visible rendering target")
        ready.assertForOverFulfill = true
        sink.beginSession(ready: { ready.fulfill() }, failure: { _ in XCTFail("Unexpected capture error") })
        sink.rtcEngine(engine, localVideoStateChangedOf: .capturing, reason: .OK, sourceType: .camera)
        sink.rtcEngine(engine, localVideoStateChangedOf: .encoding, reason: .OK, sourceType: .camera)
        sink.rtcEngine(engine, firstLocalVideoFrameWith: CGSize(width: 4, height: 4), elapsed: 0, sourceType: .camera)
        await fulfillment(of: [ready], timeout: 2)
    }

    func testOnlyFirstValidCameraRenderedEventReportsReadiness() async {
        let sink = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit()
        let ready = expectation(description: "Native preview rendered its first frame")
        ready.assertForOverFulfill = true
        sink.beginSession(ready: { ready.fulfill() }, failure: { _ in XCTFail("Unexpected camera failure") })
        sink.rtcEngine(engine, firstLocalVideoFrameWith: .zero, elapsed: 0, sourceType: .camera)
        sink.rtcEngine(engine, firstLocalVideoFrameWith: CGSize(width: 4, height: 4), elapsed: 0, sourceType: .screen)
        sink.rtcEngine(engine, firstLocalVideoFrameWith: CGSize(width: 4, height: 4), elapsed: 0, sourceType: .camera)
        sink.rtcEngine(engine, firstLocalVideoFrameWith: CGSize(width: 8, height: 8), elapsed: 0, sourceType: .camera)
        await fulfillment(of: [ready], timeout: 2)
    }

    func testLateEventsAfterStopDoNotReportReadyOrFailure() async {
        let sink = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit()
        let unexpected = expectation(description: "Stopped session must ignore late engine metadata")
        unexpected.isInverted = true
        sink.beginSession(ready: { unexpected.fulfill() }, failure: { _ in unexpected.fulfill() })
        sink.endSession()
        sink.rtcEngine(engine, firstLocalVideoFrameWith: CGSize(width: 4, height: 4), elapsed: 0, sourceType: .camera)
        sink.rtcEngine(engine, localVideoStateChangedOf: .failed, reason: .captureFailure, sourceType: .camera)
        await fulfillment(of: [unexpected], timeout: 0.1)
    }

    func testReadyCallbackCanStopItsSessionWithoutBlockingVendorCallback() async {
        let sink = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit()
        let returned = expectation(description: "Ready callback can clean up its own session")
        sink.beginSession(ready: { sink.endSession(); returned.fulfill() }, failure: { _ in })
        sink.rtcEngine(engine, firstLocalVideoFrameWith: CGSize(width: 4, height: 4), elapsed: 0, sourceType: .camera)
        await fulfillment(of: [returned], timeout: 2)
    }

    func testCameraFailurePreventsSubsequentReadinessAndReportsOnce() async {
        let sink = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit()
        let failed = expectation(description: "Capture error is forwarded")
        failed.assertForOverFulfill = true
        let ready = expectation(description: "Failed capture cannot become ready")
        ready.isInverted = true
        sink.beginSession(ready: { ready.fulfill() }, failure: { error in
            XCTAssertEqual(error.code, .mediaError)
            failed.fulfill()
        })
        sink.rtcEngine(engine, localVideoStateChangedOf: .failed, reason: .captureFailure, sourceType: .camera)
        sink.rtcEngine(engine, localVideoStateChangedOf: .failed, reason: .captureFailure, sourceType: .camera)
        sink.rtcEngine(engine, firstLocalVideoFrameWith: CGSize(width: 4, height: 4), elapsed: 0, sourceType: .camera)
        await fulfillment(of: [failed, ready], timeout: 0.1)
    }
}

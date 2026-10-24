@preconcurrency import AgoraRtcKit
import CoreVideo
import XCTest
@testable import XmaxSDK

final class RtcVideoFrameObserverTests: XCTestCase, @unchecked Sendable {
    func testObserverOnlyRequestsRemotePixelsAndCanDetachFromCallback() async throws {
        let observer = RtcVideoFrameObserver()
        XCTAssertEqual(observer.getObservedFramePosition(), .preRenderer)
        XCTAssertFalse(observer.getObservedFramePosition().contains(.postCapture))
        let received = expectation(description: "Remote pixels remain available for virtual camera output")
        received.assertForOverFulfill = true
        observer.setRemote(RtcRemoteVideoSink { _, _, frame in
            XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), 4)
            observer.setRemote(nil)
            received.fulfill()
        })
        let frame = try makeFrame()
        DispatchQueue.global().async {
            _ = observer.onRenderVideoFrame(frame, uid: 42, channelId: "test")
            _ = observer.onRenderVideoFrame(frame, uid: 42, channelId: "test")
        }
        await fulfillment(of: [received], timeout: 2)
    }

    private func makeFrame() throws -> AgoraOutputVideoFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let frame = AgoraOutputVideoFrame()
        frame.pixelBuffer = try XCTUnwrap(buffer)
        return frame
    }
}

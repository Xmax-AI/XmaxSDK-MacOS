import CoreAudio
import XCTest
@testable import XmaxSDK

final class AgoraMicrophoneDeviceTests: XCTestCase {
    func testStableUIDResolvesToEnumeratedVendorID() throws {
        let result = try AgoraRtcPlatform.resolveRecordingDeviceID(
            "BuiltInMicrophoneDevice", enumeratedIDs: ["66", "126"]
        ) { uid in
            XCTAssertEqual(uid, "BuiltInMicrophoneDevice")
            return 126
        }
        XCTAssertEqual(result, "126")
        XCTAssertNotEqual(result, "BuiltInMicrophoneDevice")
    }

    func testReconnectedDeviceUsesCurrentNumericID() throws {
        for id: AudioDeviceID in [126, 203] {
            let result = try AgoraRtcPlatform.resolveRecordingDeviceID(
                "stable-usb-uid", enumeratedIDs: [String(id)], resolveUID: { _ in id }
            )
            XCTAssertEqual(result, String(id))
        }
    }

    func testMissingDeviceDoesNotFallBackToAnotherInput() {
        for id: AudioDeviceID? in [nil, kAudioObjectUnknown, 203] {
            XCTAssertThrowsError(try AgoraRtcPlatform.resolveRecordingDeviceID(
                "missing-uid", enumeratedIDs: ["126"], resolveUID: { _ in id }
            )) { error in
                XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
            }
        }
    }

    func testUIDCannotBePassedThroughAsVendorID() {
        XCTAssertThrowsError(try AgoraRtcPlatform.resolveRecordingDeviceID(
            "stable-uid", enumeratedIDs: ["stable-uid"], resolveUID: { _ in 126 }
        ))
        XCTAssertThrowsError(try AgoraRtcPlatform.resolveRecordingDeviceID(
            "", enumeratedIDs: ["126"], resolveUID: { _ in 126 }
        ))
    }
}

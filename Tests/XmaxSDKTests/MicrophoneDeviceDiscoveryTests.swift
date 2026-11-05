import CoreAudio
import XCTest
@testable import XmaxSDK

final class MicrophoneDeviceDiscoveryTests: XCTestCase {
    func testSnapshotReturnsStableInputUIDsAndSystemDefaultSortedByName() {
        let devices = MicrophoneDeviceDiscovery.list(
            deviceIDs: { [1, 2, 3, 4] },
            defaultDeviceID: { 2 },
            readDevice: { objectID in
                switch objectID {
                case 1: ("usb-input-uid", "USB Microphone")
                case 2: ("built-in-input-uid", "Built-in Microphone")
                default: nil
                }
            }
        )
        XCTAssertEqual(devices, [
            MicrophoneDevice(id: "built-in-input-uid", name: "Built-in Microphone", isDefault: true),
            MicrophoneDevice(id: "usb-input-uid", name: "USB Microphone", isDefault: false)
        ])
    }

    func testUnavailableDefaultDoesNotMarkAnArbitraryInputAsDefault() {
        for missingDefault: AudioDeviceID? in [nil, kAudioObjectUnknown, 99] {
            let devices = MicrophoneDeviceDiscovery.list(
                deviceIDs: { [1] },
                defaultDeviceID: { missingDefault },
                readDevice: { _ in ("input-uid", "Microphone") }
            )
            XCTAssertEqual(devices.count, 1)
            XCTAssertFalse(devices[0].isDefault)
        }
    }

    func testDuplicateUIDKeepsTheDefaultAndInvalidDescriptionsAreOmitted() {
        let devices = MicrophoneDeviceDiscovery.list(
            deviceIDs: { [0, 1, 2, 3, 4] },
            defaultDeviceID: { 2 },
            readDevice: { objectID in
                switch objectID {
                case 0:
                    XCTFail("Unknown audio objects must not be queried")
                    return nil
                case 1: return ("shared-uid", "Old Description")
                case 2: return ("shared-uid", "Default Input")
                case 3: return ("", "Missing UID")
                default: return ("missing-name", "")
                }
            }
        )
        XCTAssertEqual(devices, [MicrophoneDevice(id: "shared-uid", name: "Default Input", isDefault: true)])
    }

    func testEqualNamesAreSortedByUIDAndEmptyListsRemainEmpty() {
        let devices = MicrophoneDeviceDiscovery.list(
            deviceIDs: { [2, 1] },
            defaultDeviceID: { nil },
            readDevice: { objectID in (objectID == 1 ? "a-input" : "b-input", "Microphone") }
        )
        XCTAssertEqual(devices.map(\.id), ["a-input", "b-input"])
        XCTAssertTrue(MicrophoneDeviceDiscovery.list(
            deviceIDs: { [] },
            defaultDeviceID: { nil },
            readDevice: { _ in
                XCTFail("No devices should be queried")
                return nil
            }
        ).isEmpty)
    }
}

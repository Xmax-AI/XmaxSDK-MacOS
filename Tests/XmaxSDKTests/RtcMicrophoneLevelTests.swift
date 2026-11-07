import Foundation
import XCTest
@testable import XmaxSDK

@MainActor
final class RtcMicrophoneLevelTests: XCTestCase {
    func testPublicRegistrationDoesNotInitializeRtcOrStartCapture() async {
        let platform = RtcPlatformStub()
        let creationCount = MicrophoneEngineCreationCount()
        let rtc = RtcManager(
            engineManager: RtcEngineManager(
                appID: "test",
                makeEngine: { _ in
                    creationCount.increment()
                    return platform
                },
                destroyEngine: {}
            )
        )
        let api = MicrophoneLevelAPIStub()
        let options = RealtimeConfiguration(model: .x2_1)
        let components = XmaxRealtimeFactory.make(options: options, apiService: api, rtcManager: rtc)
        let manager: any XmaxRealtimeManaging = XmaxRealtimeManager(options: options, components: components)
        var readings: [Float?] = []
        await manager.setMicrophoneLevelListener {
            MainActor.preconditionIsolated()
            readings.append($0)
        }
        XCTAssertEqual(readings.count, 1)
        XCTAssertNil(readings[0])
        XCTAssertEqual(platform.audioCaptureCount, 0)
        XCTAssertNil(platform.microphoneLevelListener)
        XCTAssertEqual(api.requestCount, 0)
        XCTAssertEqual(creationCount.value, 0)
        await manager.setMicrophoneLevelListener(nil)
        await manager.close()
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(api.requestCount, 0)
    }

    func testSwitchAndStopReplaceSourceCallbacksWithoutChangingCaptureCount() async throws {
        let platform = RtcPlatformStub()
        let manager = makeManager(platform)
        try await manager.initialize()
        var readings: [Float?] = []
        var stopping = false
        let first = expectation(description: "Original device measured")
        let second = expectation(description: "Replacement device measured")
        let stopped = expectation(description: "Stopped input cleared")
        await manager.setMicrophoneLevelListener {
            readings.append($0)
            if $0 == 0.2 { first.fulfill() }
            if $0 == 0.6 { second.fulfill() }
            if $0 == nil && stopping { stopped.fulfill() }
        }
        try manager.startAudioCapture()
        let original = try XCTUnwrap(platform.microphoneLevelListener)
        original(0.2)
        await fulfillment(of: [first], timeout: 1)
        try manager.setMicrophoneDevice("usb-input")
        let replacement = try XCTUnwrap(platform.microphoneLevelListener)
        original(1)
        replacement(0.6)
        await fulfillment(of: [second], timeout: 1)
        stopping = true
        try manager.stopAudioCapture()
        replacement(0.9)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(readings.compactMap { $0 }, [0.2, 0.6])
        XCTAssertNil(platform.microphoneLevelListener)
        XCTAssertEqual(platform.audioCaptureCount, 1)
        XCTAssertEqual(platform.audioStopCount, 1)
        await manager.setMicrophoneLevelListener(nil)
        await manager.destroy()
    }

    func testFailedStopStillInvalidatesQueuedAndLateInput() async throws {
        let platform = RtcPlatformStub(onAudioStop: {
            throw XmaxError(code: .rtcError, message: "Stop rejected")
        })
        let manager = makeManager(platform)
        try await manager.initialize()
        var readings: [Float?] = []
        await manager.setMicrophoneLevelListener { readings.append($0) }
        try manager.startAudioCapture()
        let source = try XCTUnwrap(platform.microphoneLevelListener)
        source(0.5)
        XCTAssertThrowsError(try manager.stopAudioCapture())
        source(1)
        await manager.setMicrophoneLevelListener { readings.append($0) }
        XCTAssertTrue(readings.allSatisfy { $0 == nil })
        XCTAssertNil(platform.microphoneLevelListener)
        await manager.setMicrophoneLevelListener(nil)
        await manager.destroy()
    }

    func testFailedStartDoesNotBindNativeObservation() async throws {
        let platform = RtcPlatformStub(onAudioCapture: { _ in
            throw XmaxError(code: .mediaError, message: "Input unavailable")
        })
        let manager = makeManager(platform)
        try await manager.initialize()
        var readings: [Float?] = []
        await manager.setMicrophoneLevelListener { readings.append($0) }
        XCTAssertThrowsError(try manager.startAudioCapture())
        XCTAssertNil(platform.microphoneLevelListener)
        await manager.setMicrophoneLevelListener { readings.append($0) }
        XCTAssertTrue(readings.allSatisfy { $0 == nil })
        await manager.setMicrophoneLevelListener(nil)
        await manager.destroy()
    }

    func testFailedSwitchResumesObservationOfTheRestoredInput() async throws {
        let platform = RtcPlatformStub(onMicrophoneDevice: {
            if $0 == "removed" { throw XmaxError(code: .mediaError, message: "Removed") }
        })
        let manager = makeManager(platform)
        try await manager.initialize()
        var readings: [Float?] = []
        let restored = expectation(description: "Restored input measured")
        await manager.setMicrophoneLevelListener {
            readings.append($0)
            if $0 == 0.4 { restored.fulfill() }
        }
        try manager.startAudioCapture()
        let previous = try XCTUnwrap(platform.microphoneLevelListener)
        previous(0.8)
        XCTAssertThrowsError(try manager.setMicrophoneDevice("removed"))
        previous(1)
        let current = try XCTUnwrap(platform.microphoneLevelListener)
        current(0.4)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(readings.compactMap { $0 }, [0.4])
        await manager.setMicrophoneLevelListener(nil)
        await manager.destroy()
    }

    func testExternalAudioAndDisconnectInvalidateMicrophoneReadings() async throws {
        for useExternalAudio in [true, false] {
            let platform = RtcPlatformStub()
            let manager = makeManager(platform)
            try await manager.initialize()
            var readings: [Float?] = []
            await manager.setMicrophoneLevelListener { readings.append($0) }
            try manager.startAudioCapture()
            let previous = try XCTUnwrap(platform.microphoneLevelListener)
            previous(0.8)
            if useExternalAudio { try manager.startExternalAudioSource() } else { await manager.leaveRoom() }
            previous(1)
            await manager.setMicrophoneLevelListener { readings.append($0) }
            XCTAssertNil(readings.last!)
            XCTAssertFalse(readings.contains(1), "The previous source cannot deliver after input is invalidated")
            XCTAssertNil(platform.microphoneLevelListener)
            await manager.setMicrophoneLevelListener(nil)
            await manager.destroy()
        }
    }

    func testCaptureWithoutObservationDoesNotBindNativeLevelReporting() async throws {
        let platform = RtcPlatformStub()
        let manager = makeManager(platform)
        try await manager.initialize()
        try manager.startAudioCapture()
        XCTAssertNil(platform.microphoneLevelListener)
        var readings: [Float?] = []
        await manager.setMicrophoneLevelListener { readings.append($0) }
        XCTAssertNotNil(platform.microphoneLevelListener)
        XCTAssertEqual(platform.audioCaptureCount, 1)
        await manager.setMicrophoneLevelListener(nil)
        XCTAssertNil(platform.microphoneLevelListener)
        XCTAssertEqual(platform.audioCaptureCount, 1)
        await manager.destroy()
    }

    func testDestroyAndReinitializationRejectThePreviousEngineSource() async throws {
        let platform = RtcPlatformStub()
        let manager = makeManager(platform)
        try await manager.initialize()
        var readings: [Float?] = []
        let resumed = expectation(description: "Input observation resumes after engine replacement")
        await manager.setMicrophoneLevelListener {
            readings.append($0)
            if $0 == 0.3 { resumed.fulfill() }
        }
        try manager.startAudioCapture()
        let previous = try XCTUnwrap(platform.microphoneLevelListener)
        await manager.destroy()
        XCTAssertNil(platform.microphoneLevelListener)
        previous(1)
        try await manager.initialize()
        try manager.startAudioCapture()
        let current = try XCTUnwrap(platform.microphoneLevelListener)
        previous(1)
        current(0.3)
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(readings.compactMap { $0 }, [0.3])
        await manager.setMicrophoneLevelListener(nil)
        await manager.destroy()
    }

    private func makeManager(_ platform: RtcPlatformStub) -> RtcManager {
        RtcManager(
            engineManager: RtcEngineManager(
                appID: "test",
                makeEngine: { _ in platform },
                destroyEngine: {}
            )
        )
    }
}

private final class MicrophoneEngineCreationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class MicrophoneLevelAPIStub: ApiServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.withLock { count } }

    func request<Response: Decodable & Sendable>(
        _ method: ApiMethod,
        path: String,
        body: Data?,
        as responseType: Response.Type
    ) async throws -> Response {
        lock.withLock { count += 1 }
        throw XmaxError(code: .apiError, message: "Input observation must not make network requests")
    }
}

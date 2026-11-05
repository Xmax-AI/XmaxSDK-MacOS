@preconcurrency import AgoraRtcKit
import Foundation
import XCTest
@testable import XmaxSDK

@MainActor
final class MicrophoneLevelTests: XCTestCase {
    func testRegistrationReplaysUnavailableWithoutCreatingACaptureSource() {
        let monitor = MicrophoneLevelMonitor()
        var readings: [Float?] = []
        monitor.setListener { readings.append($0) }
        XCTAssertEqual(readings.count, 1)
        XCTAssertNil(readings[0])
        XCTAssertFalse(monitor.isCapturing)
        XCTAssertNil(monitor.sourceListener())
    }

    func testBurstDeliveryIsBoundedAndPreservesTheInputClear() async throws {
        let monitor = MicrophoneLevelMonitor()
        var readings: [Float?] = []
        let delivered = expectation(description: "Newest reading delivered")
        monitor.setListener {
            readings.append($0)
            if $0 == 1 { delivered.fulfill() }
        }
        monitor.beginCapture()
        let source = try XCTUnwrap(monitor.sourceListener())
        for index in 1...1_000 { source(Float(index) / 1_000) }
        XCTAssertTrue(readings.compactMap { $0 }.isEmpty)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(readings.compactMap { $0 }, [1])
        XCTAssertNil(readings[1])
    }

    func testSilenceAndCaptureStopHaveDifferentValuesAndLateReadingsAreRejected() async throws {
        let monitor = MicrophoneLevelMonitor()
        var readings: [Float?] = []
        var measuredSilence = false
        let silence = expectation(description: "Measured silence is zero")
        let stopped = expectation(description: "Stopped input is unavailable")
        monitor.setListener { value in
            readings.append(value)
            if value == 0 {
                measuredSilence = true
                silence.fulfill()
            } else if value == nil && measuredSilence {
                stopped.fulfill()
            }
        }
        monitor.beginCapture()
        let source = try XCTUnwrap(monitor.sourceListener())
        source(0)
        await fulfillment(of: [silence], timeout: 1)
        monitor.endCapture()
        source(0.9)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertNil(readings.last!)
        XCTAssertEqual(readings.compactMap { $0 }, [0])
    }

    func testReplacingAListenerReplaysItsSnapshotAndRejectsOldQueuedDelivery() async throws {
        let monitor = MicrophoneLevelMonitor()
        var oldReadings: [Float?] = []
        var newReadings: [Float?] = []
        let delivered = expectation(description: "Replacement receives new input")
        monitor.setListener { oldReadings.append($0) }
        monitor.beginCapture()
        let source = try XCTUnwrap(monitor.sourceListener())
        source(0.5)
        monitor.setListener {
            newReadings.append($0)
            if $0 == 0.75 { delivered.fulfill() }
        }
        XCTAssertEqual(newReadings, [0.5])
        source(1)
        let replacementSource = try XCTUnwrap(monitor.sourceListener())
        replacementSource(0.75)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertTrue(oldReadings.compactMap { $0 }.isEmpty)
        XCTAssertEqual(newReadings, [0.5, 0.75])
    }

    func testRemovingTheListenerDiscardsQueuedInputAndClearsItsCachedReading() async throws {
        let monitor = MicrophoneLevelMonitor()
        let unexpected = expectation(description: "Removed observer receives nothing")
        unexpected.isInverted = true
        monitor.setListener { if $0 != nil { unexpected.fulfill() } }
        monitor.beginCapture()
        let source = try XCTUnwrap(monitor.sourceListener())
        source(0.8)
        monitor.setListener(nil)
        source(0.9)
        var replay: [Float?] = []
        monitor.setListener { replay.append($0) }
        source(1)
        XCTAssertEqual(replay.count, 1)
        XCTAssertNil(replay[0])
        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertEqual(replay.count, 1)
    }

    func testReplacingTheCaptureRejectsItsPreviousSource() async throws {
        let monitor = MicrophoneLevelMonitor()
        var readings: [Float?] = []
        let delivered = expectation(description: "Replacement input delivered")
        monitor.setListener {
            readings.append($0)
            if $0 == 0.4 { delivered.fulfill() }
        }
        monitor.beginCapture()
        let previous = try XCTUnwrap(monitor.sourceListener())
        previous(0.8)
        monitor.beginCapture()
        let current = try XCTUnwrap(monitor.sourceListener())
        previous(1)
        current(0.4)
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(readings.compactMap { $0 }, [0.4])
    }

    func testLevelsAreFiniteAndClampedToThePublicRange() async throws {
        let monitor = MicrophoneLevelMonitor()
        var readings: [Float?] = []
        let zero = expectation(description: "Negative input clamped")
        let one = expectation(description: "Oversized input clamped")
        monitor.setListener {
            readings.append($0)
            if $0 == 0 { zero.fulfill() }
            if $0 == 1 { one.fulfill() }
        }
        monitor.beginCapture()
        let source = try XCTUnwrap(monitor.sourceListener())
        source(.nan)
        source(.infinity)
        source(-2)
        await fulfillment(of: [zero], timeout: 1)
        source(2)
        await fulfillment(of: [one], timeout: 1)
        XCTAssertEqual(readings.compactMap { $0 }, [0, 1])
    }

    func testListenerCanRemoveItselfDuringTheClearBeforeFreshInput() async throws {
        let monitor = MicrophoneLevelMonitor()
        var armed = false
        var readings: [Float?] = []
        let removed = expectation(description: "Observer removes itself")
        monitor.setListener { value in
            readings.append(value)
            if armed && value == nil {
                monitor.setListener(nil)
                removed.fulfill()
            }
        }
        armed = true
        monitor.beginCapture()
        let source = try XCTUnwrap(monitor.sourceListener())
        source(0.8)
        await fulfillment(of: [removed], timeout: 1)
        XCTAssertNil(monitor.sourceListener())
        XCTAssertTrue(readings.compactMap { $0 }.isEmpty)
    }

    func testNativeVolumeUsesOnlyLocalInputAndIgnoresRemoteMixTotals() {
        let sink = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit()
        let recorder = MicrophoneReadingRecorder()
        sink.setMicrophoneLevelListener { recorder.append($0) }
        let remote = AgoraRtcAudioVolumeInfo()
        remote.uid = 42
        remote.volume = 255
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [remote], totalVolume: 255)
        XCTAssertTrue(recorder.values.isEmpty)
        let local = AgoraRtcAudioVolumeInfo()
        local.uid = 0
        local.volume = 0
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        local.volume = 128
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        local.volume = 255
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 0)
        XCTAssertEqual(recorder.values.compactMap { $0 }, [0, Float(128) / 255, 1])
    }

    func testNativeAudioFailureClearsInputWithoutChangingCameraReadiness() {
        let sink = RtcCameraEventSink()
        let recorder = MicrophoneReadingRecorder()
        sink.setMicrophoneLevelListener { recorder.append($0) }
        let engine = AgoraRtcEngineKit()
        sink.rtcEngine(engine, localAudioStateChanged: .failed, reason: .recordFailure)
        sink.rtcEngine(engine, localAudioStateChanged: .stopped, reason: .OK)
        XCTAssertEqual(recorder.values.count, 2)
        XCTAssertTrue(recorder.values.allSatisfy { $0 == nil })
        let local = AgoraRtcAudioVolumeInfo()
        local.uid = 0
        local.volume = 255
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        XCTAssertEqual(recorder.values.count, 2, "Input remains unavailable until native capture resumes")
        sink.setMicrophoneLevelListener { recorder.append($0) }
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        XCTAssertEqual(recorder.values.count, 2, "Replacing observation must not mark failed capture as valid")
        sink.rtcEngine(engine, localAudioStateChanged: .recording, reason: .OK)
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        XCTAssertEqual(recorder.values.last!, 1)
    }

    func testNativeObservationUsesTheFixedIntervalAndRemovalStopsMetadata() {
        let sink = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit()
        var intervals: [Int] = []
        let platform = AgoraRtcPlatform(
            engine: engine,
            cameraEvents: sink,
            microphoneLevelIndication: { interval, smooth, vad, _ in
                intervals.append(interval)
                XCTAssertEqual(smooth, 3)
                XCTAssertFalse(vad)
                return 0
            }
        )
        let recorder = MicrophoneReadingRecorder()
        platform.setMicrophoneLevelListener { recorder.append($0) }
        let local = AgoraRtcAudioVolumeInfo()
        local.uid = 0
        local.volume = 255
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        XCTAssertEqual(recorder.values, [1])
        platform.setMicrophoneLevelListener(nil)
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        XCTAssertEqual(recorder.values, [1])
        XCTAssertEqual(intervals, [200, 0])
    }

    func testRejectedNativeObservationLeavesNoListenerAndCanBeRetried() {
        let sink = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit()
        var acceptsObservation = false
        var intervals: [Int] = []
        let platform = AgoraRtcPlatform(
            engine: engine,
            cameraEvents: sink,
            microphoneLevelIndication: { interval, _, _, _ in
                intervals.append(interval)
                return acceptsObservation ? 0 : -1
            }
        )
        let recorder = MicrophoneReadingRecorder()
        platform.setMicrophoneLevelListener { recorder.append($0) }
        let local = AgoraRtcAudioVolumeInfo()
        local.uid = 0
        local.volume = 255
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        XCTAssertEqual(recorder.values.count, 1)
        XCTAssertNil(recorder.values[0], "Rejected observation reports an unavailable reading")
        acceptsObservation = true
        platform.setMicrophoneLevelListener { recorder.append($0) }
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        XCTAssertEqual(recorder.values, [nil, 1])
        XCTAssertEqual(intervals, [200, 200])
    }

    func testFailedNativeRemovalStillRemovesTheReceiverAndRetriesDisablingMetadata() {
        let sink = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit()
        var acceptsRemoval = false
        var intervals: [Int] = []
        let platform = AgoraRtcPlatform(
            engine: engine,
            cameraEvents: sink,
            microphoneLevelIndication: { interval, _, _, _ in
                intervals.append(interval)
                return interval > 0 || acceptsRemoval ? 0 : -1
            }
        )
        let recorder = MicrophoneReadingRecorder()
        platform.setMicrophoneLevelListener { recorder.append($0) }
        platform.setMicrophoneLevelListener(nil)
        let local = AgoraRtcAudioVolumeInfo()
        local.uid = 0
        local.volume = 255
        sink.rtcEngine(engine, reportAudioVolumeIndicationOfSpeakers: [local], totalVolume: 255)
        XCTAssertTrue(recorder.values.isEmpty)
        acceptsRemoval = true
        platform.setMicrophoneLevelListener(nil)
        platform.setMicrophoneLevelListener(nil)
        XCTAssertEqual(intervals, [200, 0, 0])
    }
}

private final class MicrophoneReadingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [Float?] = []
    var values: [Float?] { lock.withLock { readings } }
    func append(_ value: Float?) { lock.withLock { readings.append(value) } }
}

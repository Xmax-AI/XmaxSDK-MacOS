import Foundation
import XCTest
@testable import XmaxSDK

final class LocalMediaPreparationTimingTests: XCTestCase, @unchecked Sendable {
    func testNestedDurationsUseMonotonicClockWithoutDoubleCounting() throws {
        let records = TimingRecorder()
        let trace = records.makeTrace()
        LocalMediaPreparationTiming.$current.withValue(trace) {
            LocalMediaPreparationTiming.measure(.total) {
                records.advance(milliseconds: 10)
                LocalMediaPreparationTiming.measure(.engineAcquire) {
                    records.advance(milliseconds: 40)
                }
                records.advance(milliseconds: 5)
            }
        }

        let completed = records.snapshot.filter { $0.outcome != nil }
        let engine = try XCTUnwrap(completed.first { $0.stage == .engineAcquire })
        let total = try XCTUnwrap(completed.first { $0.stage == .total })
        XCTAssertEqual(engine.durationMs, 40)
        XCTAssertEqual(engine.offsetMs, 50)
        XCTAssertEqual(total.durationMs, 55)
        XCTAssertEqual(Set(records.snapshot.map(\.traceID)), [trace.id])
    }

    func testThrowingOperationKeepsOriginalErrorAndClosesFailedStage() throws {
        let records = TimingRecorder()
        let expected = XmaxError(code: .mediaError, message: "Original capture failure")
        var calls = 0
        try LocalMediaPreparationTiming.$current.withValue(records.makeTrace()) {
            XCTAssertThrowsError(try LocalMediaPreparationTiming.measure(.captureStartRunning) {
                calls += 1
                throw expected
            }) { XCTAssertEqual($0 as? XmaxError, expected) }
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(records.snapshot.count, 2)
        XCTAssertEqual(records.snapshot.last?.outcome, .failed)

        // Instrumentation without a startup trace must still execute the original operation normally.
        XCTAssertNil(LocalMediaPreparationTiming.current)
        XCTAssertEqual(LocalMediaPreparationTiming.measure(.resolveFormat) { 42 }, 42)
    }

    func testAsyncCancellationIsPreservedAndDistinguishedFromFailure() async {
        let records = TimingRecorder()
        await LocalMediaPreparationTiming.$current.withValue(records.makeTrace()) {
            do {
                try await LocalMediaPreparationTiming.measureAsync(.cameraPermission) {
                    await Task.yield()
                    throw CancellationError()
                }
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            do {
                try await LocalMediaPreparationTiming.measureAsync(.captureStart) {
                    throw XmaxError(code: .cancelled, message: "Cancelled")
                }
                XCTFail("Expected SDK cancellation")
            } catch { XCTAssertEqual((error as? XmaxError)?.code, .cancelled) }
        }
        XCTAssertEqual(records.snapshot.compactMap(\.outcome), [.cancelled, .cancelled])
    }

    func testTraceSurvivesInheritedTaskActorAndExplicitDispatchHandoff() async {
        let records = TimingRecorder()
        let trace = records.makeTrace()
        let actor = TimingProbe()
        let received = await LocalMediaPreparationTiming.$current.withValue(trace) {
            await Task { await actor.currentTraceID() }.value
        }
        XCTAssertEqual(received, trace.id)
        XCTAssertNil(LocalMediaPreparationTiming.current)

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // The real capture queue restores the trace this same way.
                LocalMediaPreparationTiming.$current.withValue(trace) {
                    LocalMediaPreparationTiming.measure(.captureStartRunning) {}
                }
                continuation.resume()
            }
        }
        XCTAssertEqual(Set(records.snapshot.map(\.traceID)), [trace.id])
        XCTAssertEqual(records.snapshot.filter { $0.outcome == .completed }.count, 2)
    }

    func testConcurrentStartupsKeepIndependentTraceContexts() async {
        let records = TimingRecorder()
        let traces = (0..<12).map { _ in records.makeTrace() }
        await withTaskGroup(of: Void.self) { group in
            for trace in traces {
                group.addTask {
                    await LocalMediaPreparationTiming.$current.withValue(trace) {
                        await LocalMediaPreparationTiming.measureAsync(.total) {
                            await Task.yield()
                            XCTAssertEqual(LocalMediaPreparationTiming.current?.id, trace.id)
                        }
                    }
                }
            }
        }
        let byTrace = Dictionary(grouping: records.snapshot, by: \.traceID)
        XCTAssertEqual(byTrace.count, traces.count)
        for trace in traces {
            XCTAssertEqual(byTrace[trace.id]?.count, 2)
            XCTAssertEqual(byTrace[trace.id]?.last?.outcome, .completed)
        }
        XCTAssertNil(LocalMediaPreparationTiming.current)
    }

    func testLateOrConcurrentCompletionEmitsOnlyOneEndRecord() async {
        let records = TimingRecorder()
        let span = records.makeTrace().begin(.firstCapturedFrame)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask { span.finish(index.isMultiple(of: 2) ? .completed : .cancelled) }
            }
        }
        XCTAssertFalse(span.finish(.failed))
        XCTAssertEqual(records.snapshot.count, 2)
        XCTAssertNotNil(records.snapshot.last?.durationMs)
    }

    func testCameraFailureIsTracedWithoutChangingCleanupOrMicrophoneBehavior() async {
        let records = TimingRecorder()
        let expected = XmaxError(code: .mediaError, message: "Capture failed")
        let capture = CameraCaptureManagingStub(
            devices: [CameraDevice(id: "test", name: "Test", isDefault: true, position: .front)],
            startError: expected
        )
        let controller = CameraController(
            rtcManager: RtcManagingStub(), permissionManager: PermissionManagingStub(),
            mediaService: MediaService(), captureManager: capture
        )
        await LocalMediaPreparationTiming.$current.withValue(records.makeTrace()) {
            do {
                _ = try await controller.createLocalCameraStream(
                    videoFormat: RealtimeVideoFormat(width: 1920, height: 1024, fps: 30), deviceID: nil
                )
                XCTFail("Expected capture failure")
            } catch { XCTAssertEqual(error as? XmaxError, expected) }
        }
        XCTAssertNil(controller.currentTrack)
        XCTAssertEqual(capture.calls, [.start("test"), .stop])
        XCTAssertEqual(records.snapshot.last?.stage, .captureStart)
        XCTAssertEqual(records.snapshot.last?.outcome, .failed)
        XCTAssertFalse(records.snapshot.contains { $0.stage == .microphonePermission })
        XCTAssertEqual(records.snapshot.filter { $0.outcome == .completed }.map(\.stage), [
            .resolveFormat, .cameraPermission, .resolveDevice, .externalVideoSource, .createPreview
        ])
    }
}

private actor TimingProbe {
    func currentTraceID() async -> UUID? {
        await LocalMediaPreparationTiming.measureAsync(.createPreview) {
            await Task.yield()
            return LocalMediaPreparationTiming.current?.id
        }
    }
}

private final class TimingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 1_000_000_000
    private var records: [LocalMediaPreparationTiming.Record] = []

    var snapshot: [LocalMediaPreparationTiming.Record] { lock.withLock { records } }

    func advance(milliseconds: UInt64) { lock.withLock { time += milliseconds * 1_000_000 } }

    func makeTrace() -> LocalMediaPreparationTiming.Trace {
        LocalMediaPreparationTiming.Trace(
            now: { self.lock.withLock { self.time } },
            emit: { record in self.lock.withLock { self.records.append(record) } }
        )
    }
}

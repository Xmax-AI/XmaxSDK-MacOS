//
//  RealtimeTimingTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import XCTest
@testable import XmaxSDK

final class RealtimeTimingTests: XCTestCase {
    override func tearDown() {
        XmaxLogger.configure(options: [])
        super.tearDown()
    }

    func testStartupHasFourSiblingStagesUnderTotalDuration() {
        XmaxLogger.configure(options: [], environment: .china)
        let state = RealtimeTiming.State(
            startedAt: 0,
            sessionStartedAt: 1000000,
            sessionFinishedAt: 151000000,
            roomJoinStartedAt: 152000000,
            roomJoinFinishedAt: 312000000,
            publicationStartedAt: 312000000,
            publicationFinishedAt: 312400000,
            signalStartedAt: 320000000,
            firstFrameAt: 1320000000,
            readyAt: 1321000000
        )

        XCTAssertEqual(RealtimeTiming.format(state), """
        实时生成启动耗时 (Realtime Generation Startup Timing)
        └─ 总耗时：1321.0 ms
           ├─ 创建会话：150.0 ms
           ├─ RTC 进房：160.0 ms
           ├─ 发布本地流：0.4 ms
           └─ 首帧到达：1000.0 ms
        """)
    }

    func testReusedConnectionDoesNotInventConnectionDurations() {
        XmaxLogger.configure(options: [], environment: .global)
        let state = RealtimeTiming.State(
            startedAt: 0,
            signalStartedAt: 1000000,
            firstFrameAt: 501000000,
            readyAt: 502000000
        )

        XCTAssertEqual(RealtimeTiming.format(state), """
        实时生成启动耗时 (Realtime Generation Startup Timing)
        └─ Total Duration: 502.0 ms
           ├─ Session Creation: —
           ├─ RTC Room Join: —
           ├─ Local Stream Publication: —
           └─ First Frame Arrival: 500.0 ms
        """)
    }

    func testFailureKeepsCompletedStagesAndMeasuresPendingStage() {
        XmaxLogger.configure(options: [], environment: .china)
        let state = RealtimeTiming.State(
            startedAt: 0,
            sessionStartedAt: 0,
            sessionFinishedAt: 100000000,
            roomJoinStartedAt: 100000000,
            roomJoinFinishedAt: 200000000,
            publicationStartedAt: 200000000,
            failureAt: 205000000
        )
        let message = RealtimeTiming.formatFailure(
            state,
            error: XmaxError(code: .rtcError, message: "publish failed")
        )

        XCTAssertTrue(message.contains("停留阶段：发布本地流"))
        XCTAssertTrue(message.contains("创建会话：100.0 ms"))
        XCTAssertTrue(message.contains("RTC 进房：100.0 ms"))
        XCTAssertTrue(message.contains("发布本地流：5.0 ms"))
        XCTAssertTrue(message.contains("首帧到达：—"))
        XCTAssertTrue(message.contains("│  ├─ 创建会话：100.0 ms"))
        XCTAssertTrue(message.contains("│  └─ 首帧到达：—"))
        XCTAssertFalse(message.contains("结果流确认"))
    }

    func testSnapshotMatchesIOSFourStagesAndTotalWithoutAddingWarmup() {
        let state = RealtimeTiming.State(
            startedAt: 10_000_000_000,
            sessionStartedAt: 10_001_000_000,
            sessionFinishedAt: 10_151_000_000,
            roomJoinStartedAt: 10_152_000_000,
            roomJoinFinishedAt: 10_312_000_000,
            publicationStartedAt: 10_312_000_000,
            publicationFinishedAt: 10_312_400_000,
            signalStartedAt: 10_320_000_000,
            firstFrameAt: 10_820_000_000,
            readyAt: 10_821_000_000
        )
        let snapshot = RealtimeTiming.snapshot(state)
        XCTAssertEqual(snapshot, RealtimeLaunchTiming(
            sessionMs: 150, rtcJoinMs: 160, publishMs: 0.4,
            firstFrameMs: 500, totalMs: 821
        ))
        XCTAssertNotEqual(snapshot.totalMs, 10_821)
        XCTAssertNotEqual(snapshot.totalMs, 1_821)
    }

    func testSnapshotDoesNotInventReusedOrIncompleteStages() {
        let snapshot = RealtimeTiming.snapshot(.init(
            startedAt: 0, signalStartedAt: 1_000_000,
            firstFrameAt: 501_000_000, readyAt: 502_000_000
        ))
        XCTAssertEqual(snapshot, RealtimeLaunchTiming(firstFrameMs: 500, totalMs: 502))
        let failed = RealtimeTiming.snapshot(.init(
            startedAt: 0, sessionStartedAt: 0, sessionFinishedAt: 20_000_000,
            roomJoinStartedAt: 20_000_000, failureAt: 30_000_000
        ))
        XCTAssertEqual(failed, RealtimeLaunchTiming(sessionMs: 20))
        let invalid = RealtimeTiming.snapshot(.init(
            startedAt: 100, sessionStartedAt: 200, sessionFinishedAt: 100,
            readyAt: 300
        ))
        XCTAssertEqual(invalid, RealtimeLaunchTiming())
    }

    @MainActor
    func testListenerPublishesCompletedStagesOnMainThread() async {
        let clock = TimingClock()
        let timing = RealtimeTiming(now: { clock.now })
        var snapshots: [RealtimeLaunchTiming] = []
        timing.setListener {
            XCTAssertTrue(Thread.isMainThread)
            snapshots.append($0)
        }
        clock.set(milliseconds: 10_000)
        timing.begin()
        clock.set(milliseconds: 10_010)
        timing.beginSessionCreation()
        clock.set(milliseconds: 10_030)
        timing.finishSessionCreation()
        clock.set(milliseconds: 10_040)
        timing.beginRoomJoin()
        clock.set(milliseconds: 10_070)
        timing.finishRoomJoin()
        clock.set(milliseconds: 10_080)
        timing.beginLocalPublication()
        clock.set(milliseconds: 10_090)
        timing.finishLocalPublication()
        clock.set(milliseconds: 10_100)
        timing.beginSignal(taskID: "task")
        clock.set(milliseconds: 10_250)
        timing.finishFirstFrame(taskID: "task")
        clock.set(milliseconds: 10_252)
        timing.finish(taskID: "task")
        await drainCallbacks()

        XCTAssertEqual(snapshots.count, 7)
        XCTAssertEqual(snapshots[2], RealtimeLaunchTiming(sessionMs: 20))
        XCTAssertEqual(snapshots[3], RealtimeLaunchTiming(sessionMs: 20, rtcJoinMs: 30))
        XCTAssertNil(snapshots[5].totalMs)
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming(
            sessionMs: 20, rtcJoinMs: 30, publishMs: 10, firstFrameMs: 150, totalMs: 252
        ))
    }

    @MainActor
    func testReplacingOrRemovingListenerInvalidatesQueuedCallbacks() async {
        let timing = RealtimeTiming()
        var removed: [RealtimeLaunchTiming] = []
        var replaced: [RealtimeLaunchTiming] = []
        timing.setListener { removed.append($0) }
        timing.begin()
        timing.setListener(nil)
        timing.setListener { replaced.append($0) }
        timing.beginSessionCreation()
        timing.finishSessionCreation()
        timing.setListener(nil)
        await drainCallbacks()
        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(replaced.isEmpty)

        var current: [RealtimeLaunchTiming] = []
        timing.setListener { current.append($0) }
        await drainCallbacks()
        XCTAssertEqual(current.count, 1)
        XCTAssertNotNil(current.first?.sessionMs)
    }

    @MainActor
    func testCompletedStartupIsFrozenAndNextStartupResetsStages() async {
        let clock = TimingClock()
        let timing = RealtimeTiming(now: { clock.now })
        var snapshots: [RealtimeLaunchTiming] = []
        timing.setListener { snapshots.append($0) }
        timing.begin()
        timing.beginSignal(taskID: "initial")
        clock.set(milliseconds: 20)
        timing.finishFirstFrame(taskID: "initial")
        clock.set(milliseconds: 21)
        timing.finish(taskID: "initial")
        await drainCallbacks()
        let completedCount = snapshots.count
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming(firstFrameMs: 20, totalMs: 21))

        clock.set(milliseconds: 500)
        timing.beginSignal(taskID: "updated")
        timing.finishFirstFrame(taskID: "updated")
        timing.finish(taskID: "updated")
        timing.beginRoomJoin()
        timing.finishRoomJoin()
        await drainCallbacks()
        XCTAssertEqual(snapshots.count, completedCount)

        timing.begin()
        await drainCallbacks()
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming())
    }

    @MainActor
    func testStaleTaskCannotCompleteNewStartupAndFirstFrameIsRequired() async {
        let clock = TimingClock()
        let timing = RealtimeTiming(now: { clock.now })
        var snapshots: [RealtimeLaunchTiming] = []
        timing.setListener { snapshots.append($0) }
        timing.begin()
        timing.beginSignal(taskID: "old")
        clock.set(milliseconds: 10)
        timing.begin()
        timing.beginSignal(taskID: "new")
        timing.finishFirstFrame(taskID: "old")
        timing.finish(taskID: "old")
        timing.finish(taskID: "new")
        await drainCallbacks()
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming())
        clock.set(milliseconds: 30)
        timing.finishFirstFrame(taskID: "new")
        clock.set(milliseconds: 31)
        timing.finish(taskID: "new")
        await drainCallbacks()
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming(firstFrameMs: 20, totalMs: 21))
    }

    @MainActor
    func testFailureKeepsCompletedStagesWithoutSuccessfulTotal() async {
        let clock = TimingClock()
        let timing = RealtimeTiming(now: { clock.now })
        var snapshots: [RealtimeLaunchTiming] = []
        timing.setListener { snapshots.append($0) }
        timing.begin()
        timing.beginSessionCreation()
        clock.set(milliseconds: 15)
        timing.finishSessionCreation()
        timing.beginRoomJoin()
        clock.set(milliseconds: 40)
        timing.finishFailure(XmaxError(code: .rtcError, message: "fixture failure"))
        timing.finishRoomJoin()
        await drainCallbacks()
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming(sessionMs: 15))
    }

    @MainActor
    func testCameraTimingPublishesBeforeGenerationAndSurvivesItsStart() async {
        let clock = TimingClock()
        let timing = RealtimeTiming(now: { clock.now })
        var snapshots: [RealtimeLaunchTiming] = []
        timing.setListener { snapshots.append($0) }
        clock.set(milliseconds: 100)
        timing.beginCameraPreparation()
        await drainCallbacks()
        XCTAssertNil(snapshots.last?.cameraMs)
        clock.set(milliseconds: 450)
        timing.finishCameraPreparation()
        await drainCallbacks()
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming(cameraMs: 350))

        clock.set(milliseconds: 1_000)
        timing.begin(preservingCameraPreparation: true)
        timing.beginSignal(taskID: "task")
        clock.set(milliseconds: 1_100)
        timing.finishFirstFrame(taskID: "task")
        timing.finish(taskID: "task")
        await drainCallbacks()
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming(cameraMs: 350, firstFrameMs: 100, totalMs: 100))

        timing.begin()
        await drainCallbacks()
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming(), "External input must not inherit camera startup timing")
    }

    @MainActor
    func testOverlappingCameraAndCloudTimingDoesNotAddCameraToTotal() async {
        let clock = TimingClock()
        let timing = RealtimeTiming(now: { clock.now })
        var snapshots: [RealtimeLaunchTiming] = []
        timing.setListener { snapshots.append($0) }
        timing.begin()
        timing.beginCameraPreparation()
        clock.set(milliseconds: 10)
        timing.beginSessionCreation()
        clock.set(milliseconds: 30)
        timing.finishSessionCreation()
        timing.beginRoomJoin()
        clock.set(milliseconds: 200)
        timing.finishCameraPreparation()
        clock.set(milliseconds: 300)
        timing.finishRoomJoin()
        timing.beginSignal(taskID: "task")
        clock.set(milliseconds: 400)
        timing.finishFirstFrame(taskID: "task")
        timing.finish(taskID: "task")
        await drainCallbacks()
        XCTAssertEqual(snapshots.last, RealtimeLaunchTiming(
            cameraMs: 200, sessionMs: 20, rtcJoinMs: 270, firstFrameMs: 100, totalMs: 400
        ))
    }

    @MainActor
    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

}


private final class TimingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var now: UInt64 { lock.withLock { value } }

    func set(milliseconds: UInt64) {
        lock.withLock { value = milliseconds * 1_000_000 }
    }
}

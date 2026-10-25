//
//  RealtimeTiming.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Records the duration of each realtime generation startup stage.
final class RealtimeTiming: @unchecked Sendable {

    /// The lock protecting stage timestamps across threads.
    private let lock = NSLock()

    /// The timing record for the current generation startup.
    private var state = State()

    /// Whether a generation startup measurement is in progress.
    private var isMeasuring = false

    /// The clock supplying measurement times.
    private let now: @Sendable () -> UInt64

    /// The main-actor callback receiving timing snapshots.
    private var listener: RealtimeLaunchTimingListener?

    /// The identity used to discard delivery to a replaced listener.
    private var listenerID = UUID()

    /// The current timing snapshot revision.
    private var revision: UInt64 = 0

    /// The latest revision delivered to the current listener.
    private var deliveredRevision: UInt64 = 0

    /// Creates a startup recorder using a monotonic clock.
    ///
    /// - Parameter now: The clock returning nanoseconds; tests can inject a deterministic time sequence.
    init(
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.now = now
    }

    /// Sets the observer and delivers the current snapshot; replacing or clearing it invalidates queued callbacks.
    ///
    /// - Parameter listener: The main-thread callback; `nil` clears the observer.
    func setListener(
        _ listener: RealtimeLaunchTimingListener?
    ) {
        lock.withLock {
            self.listener = listener
            listenerID = UUID()
            publishLocked()
        }
    }

    /// Begins a new generation startup measurement.
    func begin() {
        lock.withLock {
            state = State(startedAt: now())
            isMeasuring = true
            publishLocked()
        }
    }

    /// Records the start of server session creation.
    func beginSessionCreation() {
        lock.withLock {
            guard isMeasuring else { return }
            state.sessionStartedAt = now()
        }
    }

    /// Records the completion of server session creation.
    func finishSessionCreation() {
        lock.withLock {
            guard isMeasuring else { return }
            state.sessionFinishedAt = now()
            publishLocked()
        }
    }

    /// Records the start of the RTC join.
    func beginRoomJoin() {
        lock.withLock {
            guard isMeasuring else { return }
            state.roomJoinStartedAt = now()
        }
    }

    /// Records the completion of the RTC join.
    func finishRoomJoin() {
        lock.withLock {
            guard isMeasuring else { return }
            state.roomJoinFinishedAt = now()
            publishLocked()
        }
    }

    /// Records the start of local stream publication.
    func beginLocalPublication() {
        lock.withLock {
            guard isMeasuring else { return }
            state.publicationStartedAt = now()
        }
    }

    /// Records the completion of local stream publication.
    func finishLocalPublication() {
        lock.withLock {
            guard isMeasuring else { return }
            state.publicationFinishedAt = now()
            publishLocked()
        }
    }

    /// Records when the generation request starts sending and resets its first-frame timestamp.
    ///
    /// - Parameter taskID: The generation task identifier.
    func beginSignal(
        taskID: String
    ) {
        lock.withLock {
            guard isMeasuring else { return }
            state.taskID = taskID
            state.signalStartedAt = now()
            state.firstFrameAt = nil
        }
    }

    /// Records when the current task's first result frame becomes displayable.
    ///
    /// - Parameter taskID: The result frame task identifier; notifications for other tasks are ignored.
    func finishFirstFrame(
        taskID: String
    ) {
        lock.withLock {
            guard isMeasuring, state.taskID == taskID, state.firstFrameAt == nil else { return }
            state.firstFrameAt = now()
            publishLocked()
        }
    }

    /// Records startup completion and logs the full timing summary when performance logging is enabled.
    ///
    /// - Parameter taskID: The completed startup task identifier; notifications for other tasks are ignored.
    func finish(
        taskID: String
    ) {
        let snapshot = lock.withLock { () -> State? in
            guard isMeasuring, state.taskID == taskID,
                state.startedAt != nil, state.firstFrameAt != nil
            else {
                return nil
            }
            state.readyAt = now()
            isMeasuring = false
            publishLocked()
            return state
        }
        guard let snapshot else { return }

        XmaxLogger.realtime.info(
            message: Self.format(snapshot),
            option: .performance
        )
    }

    /// Records startup failure and logs incomplete stage durations when enabled; cancellation is not failure.
    ///
    /// - Parameter error: The error that caused startup to fail.
    func finishFailure(
        _ error: any Error
    ) {
        let xmaxError = XmaxError.from(error)
        guard xmaxError.code != .cancelled else { return }

        let snapshot = lock.withLock { () -> State? in
            guard isMeasuring, state.startedAt != nil else { return nil }
            state.failureAt = now()
            isMeasuring = false
            publishLocked()
            return state
        }
        guard let snapshot else { return }

        XmaxLogger.realtime.info(
            message: Self.formatFailure(
                snapshot,
                error: xmaxError
            ),
            option: .performance
        )
    }
}

extension RealtimeTiming {

    /// Stores stage timestamps and task identity for one startup, using monotonic nanoseconds.
    struct State: Sendable {

        /// The start of the generation startup request.
        var startedAt: UInt64?

        /// The start of server session creation.
        var sessionStartedAt: UInt64?

        /// The completion of server session creation.
        var sessionFinishedAt: UInt64?

        /// The start of RTC room join.
        var roomJoinStartedAt: UInt64?

        /// The completion of RTC room join.
        var roomJoinFinishedAt: UInt64?

        /// The start of local stream publication.
        var publicationStartedAt: UInt64?

        /// The completion of local stream publication.
        var publicationFinishedAt: UInt64?

        /// The start of generation signaling.
        var signalStartedAt: UInt64?

        /// The time the first result frame becomes ready.
        var firstFrameAt: UInt64?

        /// The completion of generation startup.
        var readyAt: UInt64?

        /// The time startup fails.
        var failureAt: UInt64?

        /// The generation task associated with this timing record.
        var taskID: String?
    }

    /// Converts completed stage timestamps into a millisecond startup snapshot.
    ///
    /// - Parameter state: The startup record; returns an empty snapshot before startup begins.
    ///
    /// - Returns: Four generation stages and total duration; incomplete stages are `nil`.
    static func snapshot(
        _ state: State
    ) -> RealtimeLaunchTiming {

        /// Converts a measured interval to milliseconds when both endpoints exist.
        func milliseconds(
            _ start: UInt64?,
            _ end: UInt64?
        ) -> Double? {
            guard let start, let end, end >= start else { return nil }
            return Double(end - start) / 1_000_000
        }
        guard state.startedAt != nil else { return RealtimeLaunchTiming() }
        return RealtimeLaunchTiming(
            sessionMs: milliseconds(
                state.sessionStartedAt,
                state.sessionFinishedAt
            ),
            rtcJoinMs: milliseconds(
                state.roomJoinStartedAt,
                state.roomJoinFinishedAt
            ),
            publishMs: milliseconds(
                state.publicationStartedAt,
                state.publicationFinishedAt
            ),
            firstFrameMs: milliseconds(
                state.signalStartedAt,
                state.firstFrameAt
            ),
            totalMs: state.firstFrameAt == nil
                ? nil
                : milliseconds(
                    state.startedAt,
                    state.readyAt
                )
        )
    }

    /// Formats a successful generation startup timing summary.
    ///
    /// - Parameter state: The record containing startup and stage timestamps.
    ///
    /// - Returns: The total and stage durations, or an unavailable message if required timestamps are missing.
    static func format(
        _ state: State
    ) -> String {
        guard let startedAt = state.startedAt,
            state.firstFrameAt != nil,
            let readyAt = state.readyAt
        else {
            return "实时生成启动耗时不可用 " + "(Realtime Generation Startup Timing Unavailable)"
        }

        let lines =
            [
                "实时生成启动耗时 (Realtime Generation Startup Timing)",
                "└─ \(XmaxLogger.localized("总耗时：", "Total Duration: "))\(duration(startedAt, readyAt))"
            ] + stageDetails(state)
        return lines.joined(separator: "\n")
    }

    /// Formats an incomplete generation startup timing summary.
    ///
    /// - Parameters:
    ///   - state: The record containing the failure time and recorded stage timestamps.
    ///   - error: The SDK error that caused startup to fail.
    ///
    /// - Returns: Elapsed time, stage durations, current stage, and failure reason for logging.
    static func formatFailure(
        _ state: State,
        error: XmaxError
    ) -> String {
        guard let startedAt = state.startedAt,
            let failureAt = state.failureAt
        else {
            return "实时生成启动失败耗时不可用 " + "(Realtime Generation Startup Failure Timing Unavailable)"
        }

        let lines =
            [
                "实时生成启动未完成耗时 (Incomplete Realtime Generation Startup Timing)",
                "├─ \(XmaxLogger.localized("已耗时：", "Elapsed Time: "))\(duration(startedAt, failureAt))"
            ]
            + stageDetails(
                state,
                failureAt: failureAt
            ) + [
                "├─ \(XmaxLogger.localized("停留阶段：", "Current Stage: "))\(pendingStage(state))",
                "└─ \(XmaxLogger.localized("失败原因：", "Failure Reason: "))\(error.localizedDescription)"
            ]
        return lines.joined(separator: "\n")
    }
}

private extension RealtimeTiming {

    /// Queues immutable snapshots under the lock without invoking host callbacks inside it.
    func publishLocked() {
        guard let listener else { return }
        let snapshot = Self.snapshot(state)
        let listenerID = listenerID
        revision += 1
        let revision = revision
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isCurrent = self.lock.withLock {
                guard self.listenerID == listenerID, revision > self.deliveredRevision else { return false }
                self.deliveredRevision = revision
                return true
            }
            if isCurrent { listener(snapshot) }
        }
    }

    /// Formats the startup stage durations.
    ///
    /// - Parameters:
    ///   - state: The recorded startup timestamps.
    ///   - failureAt: The failure timestamp used as the end of unfinished stages, if supplied.
    ///
    /// - Returns: The stage detail lines for the timing summary.
    static func stageDetails(
        _ state: State,
        failureAt: UInt64? = nil
    ) -> [String] {
        let stages: [(String, UInt64?, UInt64?)] = [
            (
                XmaxLogger.localized(
                    "创建会话：",
                    "Session Creation: "
                ),
                state.sessionStartedAt, state.sessionFinishedAt
            ),
            (
                XmaxLogger.localized(
                    "RTC 进房：",
                    "RTC Room Join: "
                ),
                state.roomJoinStartedAt, state.roomJoinFinishedAt
            ),
            (
                XmaxLogger.localized(
                    "发布本地流：",
                    "Local Stream Publication: "
                ),
                state.publicationStartedAt, state.publicationFinishedAt
            ),
            (
                XmaxLogger.localized(
                    "首帧到达：",
                    "First Frame Arrival: "
                ),
                state.signalStartedAt, state.firstFrameAt
            )
        ]

        return stages.enumerated().map { index, stage in
            let indent = failureAt == nil ? "   " : "│  "
            let branch = index == stages.count - 1 ? "└─" : "├─"
            return "\(indent)\(branch) \(stage.0)\(duration(stage.1, stage.2 ?? failureAt))"
        }
    }

    /// Determines the current startup stage from recorded timestamps.
    ///
    /// - Parameter state: The startup stage timestamps.
    ///
    /// - Returns: The stage name in the current log language.
    static func pendingStage(
        _ state: State
    ) -> String {
        if state.firstFrameAt != nil {
            return XmaxLogger.localized(
                "首帧已就绪，正在完成启动",
                "First Frame Ready, Completing Startup"
            )
        }
        if state.signalStartedAt != nil {
            return XmaxLogger.localized(
                "等待首帧到达",
                "Waiting for First Frame"
            )
        }
        if state.publicationFinishedAt != nil {
            return XmaxLogger.localized(
                "准备生成",
                "Preparing Generation"
            )
        }
        if state.publicationStartedAt != nil {
            return XmaxLogger.localized(
                "发布本地流",
                "Publishing Local Stream"
            )
        }
        if state.roomJoinFinishedAt != nil {
            return XmaxLogger.localized(
                "准备发布本地流",
                "Preparing Local Stream Publication"
            )
        }
        if state.roomJoinStartedAt != nil {
            return XmaxLogger.localized(
                "RTC 进房",
                "Joining RTC Room"
            )
        }
        if state.sessionFinishedAt != nil {
            return XmaxLogger.localized(
                "RTC 连接准备",
                "RTC Connection Setup"
            )
        }
        if state.sessionStartedAt != nil {
            return XmaxLogger.localized(
                "创建会话",
                "Creating Session"
            )
        }
        return XmaxLogger.localized(
            "调用与本地准备",
            "Invocation and Local Preparation"
        )
    }

    /// Formats the interval between two nanosecond timestamps as milliseconds.
    ///
    /// - Parameters:
    ///   - start: The stage start time.
    ///   - end: The stage end time.
    ///
    /// - Returns: Milliseconds with one decimal place, or an em dash for missing or reversed timestamps.
    static func duration(
        _ start: UInt64?,
        _ end: UInt64?
    ) -> String {
        guard let start, let end, end >= start else { return "—" }
        return String(
            format: "%.1f ms",
            Double(end - start) / 1000000
        )
    }
}

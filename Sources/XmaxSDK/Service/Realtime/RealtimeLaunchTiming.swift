//
//  RealtimeLaunchTiming.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Realtime generation startup timing in milliseconds for four stages and the total duration.
///
/// Stages that have not completed are `nil`. Total timing begins when generation enters the business flow
/// and ends after the first frame is ready and generation startup completes. Total timing is measured
/// directly, not by adding stage durations.
public struct RealtimeLaunchTiming: Equatable, Sendable {

    /// The time spent creating the server session.
    public let sessionMs: Double?

    /// The time from the RTC join call to a successful join.
    public let rtcJoinMs: Double?

    /// The time spent publishing local media streams.
    public let publishMs: Double?

    /// The time from sending the generation signal to the first displayable result frame.
    public let firstFrameMs: Double?

    /// The complete duration of this generation startup flow.
    public let totalMs: Double?

    /// Creates a startup timing snapshot with incomplete stages set to `nil`.
    public init(
        sessionMs: Double? = nil,
        rtcJoinMs: Double? = nil,
        publishMs: Double? = nil,
        firstFrameMs: Double? = nil,
        totalMs: Double? = nil
    ) {
        self.sessionMs = sessionMs
        self.rtcJoinMs = rtcJoinMs
        self.publishMs = publishMs
        self.firstFrameMs = firstFrameMs
        self.totalMs = totalMs
    }
}

/// Main-thread startup timing callback; all stages reset for each generation startup.
public typealias RealtimeLaunchTimingListener = @MainActor @Sendable (RealtimeLaunchTiming) -> Void

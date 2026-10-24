//
//  RealtimeLaunchTiming.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Realtime startup timing in milliseconds: camera startup and the four generation stages.
///
/// Stages that have not completed are `nil`. Total timing begins when generation enters the business flow
/// and ends after the first frame is ready and generation state is committed. The combined camera API includes camera preparation.
/// Camera startup may overlap cloud connection. Total timing is measured directly, not by adding stage durations.
public struct RealtimeLaunchTiming: Equatable, Sendable {

    /// Time from camera preparation to capture readiness, including permissions and RTC initialization when needed.
    /// Excludes preview binding and display; nil for external input or before camera startup completes.
    public let cameraMs: Double?

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
    ///
    /// - Parameters:
    ///   - cameraMs: Camera startup time in milliseconds.
    ///   - sessionMs: Session creation time in milliseconds.
    ///   - rtcJoinMs: RTC join time in milliseconds.
    ///   - publishMs: Local stream publication time in milliseconds.
    ///   - firstFrameMs: Time from generation signal to the first frame, in milliseconds.
    ///   - totalMs: Total startup time in milliseconds.
    public init(
        cameraMs: Double? = nil,
        sessionMs: Double? = nil,
        rtcJoinMs: Double? = nil,
        publishMs: Double? = nil,
        firstFrameMs: Double? = nil,
        totalMs: Double? = nil
    ) {
        self.cameraMs = cameraMs
        self.sessionMs = sessionMs
        self.rtcJoinMs = rtcJoinMs
        self.publishMs = publishMs
        self.firstFrameMs = firstFrameMs
        self.totalMs = totalMs
    }
}

/// Main-thread startup timing callback; resets generation stages for each startup and retains timing for an existing camera.
public typealias RealtimeLaunchTimingListener = @MainActor @Sendable (RealtimeLaunchTiming) -> Void

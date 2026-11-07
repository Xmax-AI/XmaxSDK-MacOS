//
//  QualityDirection.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The sampling and adaptation policy for one transport direction.
struct QualityDirection: Sendable {

    /// The resolved media baseline, unchanged by quality levels.
    let baseline: RealtimeVideoFormat

    /// Whether this policy governs downlink rather than uplink.
    let downlink: Bool

    /// The minimum uplink area, in pixels; ignored for downlink.
    let minimumInputPixels: Int

    /// The current quality level.
    private(set) var level: RealtimeQualityLevel

    /// The consecutive good sample count.
    private var goodSamples = 0

    /// The consecutive poor sample count.
    private var poorSamples = 0

    /// The last valid monotonic sample time, in seconds.
    private var lastSample: TimeInterval?

    /// The adjustment stabilization deadline, in seconds.
    private var stableUntil: TimeInterval = 0

    /// The earliest next upgrade time, in seconds.
    private var upgradeAfter: TimeInterval = 0

    /// The post-upgrade probing deadline, in seconds.
    private var probeUntil: TimeInterval = 0

    /// Creates a directional policy with a supported initial level.
    ///
    /// - Parameters:
    ///   - baseline: The media baseline, unchanged by adaptation.
    ///   - level: The initial level. Uplink levels increase in quality until the bitrate budget is
    ///     supported.
    ///   - downlink: Whether this is the downlink direction.
    ///   - minimumInputPixels: The minimum uplink area, in pixels; ignored for downlink.
    init(
        baseline: RealtimeVideoFormat,
        level: RealtimeQualityLevel,
        downlink: Bool,
        minimumInputPixels: Int = 0
    ) {
        self.baseline = baseline
        self.downlink = downlink
        self.minimumInputPixels = minimumInputPixels
        self.level = level
        while !downlink,
            !Self.supportsUplink(format(at: self.level)),
            let higher = RealtimeQualityLevel(rawValue: self.level.rawValue - 1)
        {
            self.level = higher
        }
    }

    /// Resolves a quality level's transport format.
    ///
    /// - Parameter level: The target quality level.
    ///
    /// - Returns: The format derived from the baseline and direction.
    private func format(
        at level: RealtimeQualityLevel
    ) -> RealtimeVideoFormat {
        QualityVideoFormat.resolve(
            baseline,
            level: level,
            downlink: downlink,
            minimumInputPixels: minimumInputPixels
        )
    }

    /// Clears consecutive quality samples and their last timestamp.
    mutating func resetSamples() {
        goodSamples = 0
        poorSamples = 0
        lastSample = nil
    }

    /// Proposes a level from valid consecutive samples and cooldown rules.
    ///
    /// - Parameters:
    ///   - quality: The current network quality.
    ///   - sampledAt: The monotonic sample time, in seconds.
    ///   - now: The monotonic time, in seconds.
    ///
    /// - Returns: The candidate level, or `nil` if no change is needed.
    mutating func observe(
        _ quality: RealtimeNetworkQualityLevel,
        sampledAt: TimeInterval,
        now: TimeInterval
    ) -> RealtimeQualityLevel? {
        guard sampledAt <= now,
            lastSample.map({
                sampledAt > $0
            }) ?? true
        else {
            return nil
        }

        if let lastSample, sampledAt - lastSample > 5 {
            resetSamples()
        }
        lastSample = sampledAt

        guard now - sampledAt <= 5, now >= stableUntil else {
            goodSamples = 0
            poorSamples = 0
            return nil
        }

        let step: Int
        switch quality {
        case .bad, .veryBad:
            goodSamples = 0
            poorSamples += 1
            guard poorSamples >= 3 else {
                return nil
            }
            step = 1
        case .excellent, .good:
            poorSamples = 0
            goodSamples += 1
            guard goodSamples >= 5, now >= upgradeAfter else {
                return nil
            }
            step = -1
        default:
            goodSamples = 0
            poorSamples = 0
            return nil
        }

        var nextLevel = RealtimeQualityLevel(rawValue: level.rawValue + step)
        guard nextLevel != nil else { return nil }
        let currentFormat = format(at: level)
        while let candidate = nextLevel {
            let candidateFormat = format(at: candidate)
            if candidateFormat != currentFormat, downlink || Self.supportsUplink(candidateFormat) {
                return candidate
            }
            nextLevel = RealtimeQualityLevel(rawValue: candidate.rawValue + step)
        }
        return nil
    }

    /// Records adjustment success and updates stabilization and cooldown.
    ///
    /// - Parameters:
    ///   - next: The attempted quality level.
    ///   - success: Whether the level was applied.
    ///   - now: The monotonic time, in seconds.
    mutating func complete(
        level next: RealtimeQualityLevel,
        success: Bool,
        now: TimeInterval
    ) {
        resetSamples()
        stableUntil = now + 4
        guard success else {
            return
        }

        if next.rawValue < level.rawValue {
            probeUntil = now + 20
        } else if next.rawValue > level.rawValue {
            if now < probeUntil {
                upgradeAfter = now + 60
            }
            probeUntil = 0
        }

        level = next
    }

    /// Checks whether an uplink format has a valid bitrate budget.
    private static func supportsUplink(
        _ format: RealtimeVideoFormat
    ) -> Bool {
        (try? EncodingBitratePolicy.resolve(format)) != nil
    }
}

//
//  QualityDirection.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Network sampling and tier adjustment rules for one transport direction.
struct QualityDirection: Sendable {

    /// Media baseline
    let baseline: RealtimeVideoFormat
    let downlink: Bool
    let minimumInputPixels: Int

    /// Current tier
    private(set) var level: Int

    /// Sampling window
    private var goodSamples = 0
    private var poorSamples = 0
    private var lastSample: TimeInterval?
    private var stableUntil: TimeInterval = 0
    private var upgradeAfter: TimeInterval = 0
    private var probeUntil: TimeInterval = 0

    /// Creates a directional quality policy and resolves an available initial tier.
    ///
    /// - Parameters:
    ///   - baseline: The original media format, unchanged by tier adjustments.
    ///   - level: The initial tier, clamped to `1...5`.
    ///   - downlink: Whether this is the downstream direction.
    ///   - minimumInputPixels: The model's minimum uplink area; ignored for downlink.
    init(baseline: RealtimeVideoFormat, level: Int, downlink: Bool, minimumInputPixels: Int = 0) {
        self.baseline = baseline
        self.downlink = downlink
        self.minimumInputPixels = minimumInputPixels
        self.level = min(5, max(1, level))
        while self.level > 1, !supports(self.level) { self.level -= 1 }
    }

    /// Current transport format
    var format: RealtimeVideoFormat { format(at: level) }

    /// Calculates the transport format for a tier.
    ///
    /// - Parameter level: The target transport tier.
    /// - Returns: The format resolved from the current media baseline and direction.
    func format(at level: Int) -> RealtimeVideoFormat {
        QualityVideoFormat.resolve(baseline, level: level, downlink: downlink, minimumInputPixels: minimumInputPixels)
    }

    /// Clears consecutive good and poor network samples and the last sample time.
    mutating func resetSamples() {
        goodSamples = 0
        poorSamples = 0
        lastSample = nil
    }

    /// Proposes tier changes from valid consecutive samples and cooldown conditions.
    ///
    /// - Parameters:
    ///   - quality: The current network quality level.
    ///   - sampledAt: The quality sample's monotonic timestamp in seconds.
    ///   - now: The current monotonic timestamp in seconds.
    /// - Returns: The actionable candidate tier, or `nil` if no adjustment is needed.
    mutating func observe(_ quality: RealtimeNetworkQualityLevel, sampledAt: TimeInterval, now: TimeInterval) -> Int? {
        guard sampledAt <= now, lastSample.map({ sampledAt > $0 }) ?? true else { return nil }
        if let lastSample, sampledAt - lastSample > 5 { resetSamples() }
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
            guard poorSamples >= 3 else { return nil }
            step = 1
        case .excellent, .good:
            poorSamples = 0
            goodSamples += 1
            guard goodSamples >= 5, now >= upgradeAfter else { return nil }
            step = -1
        default:
            goodSamples = 0
            poorSamples = 0
            return nil
        }

        var candidate = level + step
        while (1...5).contains(candidate) {
            if format(at: candidate) != format, supports(candidate) { return candidate }
            candidate += step
        }
        return nil
    }

    /// Records adjustment results and updates the stability window and upgrade cooldown.
    ///
    /// - Parameters:
    ///   - next: The attempted target tier.
    ///   - success: Whether the tier applied successfully.
    ///   - now: The current monotonic timestamp in seconds.
    mutating func complete(level next: Int, success: Bool, now: TimeInterval) {
        resetSamples()
        stableUntil = now + 4
        guard success else { return }
        if next < level {
            probeUntil = now + 20
        } else if next > level {
            if now < probeUntil { upgradeAfter = now + 60 }
            probeUntil = 0
        }
        level = next
    }

    /// Checks whether a tier meets the current direction's encoding budget.
    ///
    /// - Parameter level: The tier to validate.
    /// - Returns: `true` if the downstream or upstream bitrate budget resolves successfully.
    func supports(_ level: Int) -> Bool {
        downlink || (try? EncodingBitratePolicy.resolve(format(at: level))) != nil
    }
}

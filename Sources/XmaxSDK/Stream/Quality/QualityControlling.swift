//
//  QualityControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines network quality and device performance alarm observation.
protocol QualityControlling: Sendable {

    /// The current connection's transport tiers; nil before preparation.
    var qualityConfiguration: QualityConfiguration? { get }

    /// Prepares transport tiers from the media baseline and model history.
    ///
    /// - Parameters:
    ///   - baseline: The original local media output format, unchanged by tier adjustments.
    ///   - model: The model identifier isolating tier history.
    ///
    /// - Returns: The initial upstream and downstream configuration for this connection.
    func prepareQuality(
        baseline: RealtimeVideoFormat,
        model: String
    ) -> QualityConfiguration

    /// Sets the internal adaptive sample listener without replacing the caller's network listener.
    ///
    /// - Parameter listener: Receives network quality and monotonic sample time; nil removes it.
    func setAdaptiveQualityListener(
        _ listener: (@Sendable (RealtimeNetworkQuality, TimeInterval) -> Void)?
    )

    /// Calculates candidate tiers from a sample without committing them early.
    ///
    /// - Parameters:
    ///   - quality: The current upstream and downstream network quality.
    ///   - sampledAt: The monotonic sample time in seconds.
    ///
    /// - Returns: The candidate tiers meeting consecutive sample and cooldown requirements.
    func proposeQuality(
        _ quality: RealtimeNetworkQuality,
        sampledAt: TimeInterval
    ) -> QualityChange

    /// Commits one direction's outcome, saving tier history only on success.
    ///
    /// - Parameters:
    ///   - downlink: true indicates downstream; false indicates upstream.
    ///   - level: The attempted tier in 1...5.
    ///   - success: Whether configuration applied successfully.
    func completeQuality(
        downlink: Bool,
        level: Int,
        success: Bool
    )

    /// Clears consecutive samples so busy-period history cannot trigger tier changes.
    func resetQualitySamples()

    /// Releases this connection's tier state and internal sample listener.
    func resetQuality()

    /// Sets upstream statistics reception and notifies listeners to clear old metrics.
    ///
    /// - Parameter enabled: Whether local video is published.
    func setUplinkVideoStatisticsEnabled(
        _ enabled: Bool
    )

    /// Sets the downstream target user and notifies listeners to clear old metrics.
    ///
    /// - Parameter userID: The result stream user identifier; nil stops reception.
    func setDownlinkVideoStatisticsUser(
        _ userID: String?
    )

    /// Sets the upstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil before publication or after disconnect. Pass nil to
    ///   clear it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    )

    /// Sets the downstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil when the result stream is cleared. Pass nil to
    ///   clear it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    )

    /// Sets the upstream and downstream network quality listener.
    ///
    /// - Parameter listener: The main-thread network quality callback; `nil` clears it.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    )

    /// Sets the device performance alarm listener.
    ///
    /// - Parameter listener: The main-thread performance limitation or recovery callback; `nil` clears it.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    )
}

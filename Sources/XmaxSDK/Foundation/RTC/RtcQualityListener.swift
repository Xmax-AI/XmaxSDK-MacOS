//
//  RtcQualityListener.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Neutral RTC network quality levels.
enum RtcQualityLevel: Int, CaseIterable, Sendable {

    /// No quality rating is available.
    case unknown

    /// Excellent network quality.
    case excellent

    /// Good network quality.
    case good

    /// Fair network quality.
    case poor

    /// Poor network quality.
    case bad

    /// Very poor network quality.
    case veryBad

    /// The network connection is unavailable.
    case down
}

/// Receives RTC network quality and performance fallback events.
protocol RtcQualityListener: AnyObject {

    /// Receives local upstream video statistics.
    ///
    /// - Parameter statistics: The upstream metrics for this reporting interval.
    @MainActor
    func onUplinkVideoStatistics(
        _ statistics: UplinkVideoStatistics
    )

    /// Receives remote downstream video statistics.
    ///
    /// - Parameter statistics: The downstream metrics for this reporting interval.
    @MainActor
    func onDownlinkVideoStatistics(
        _ statistics: DownlinkVideoStatistics
    )

    /// Receives realtime upstream and downstream network quality.
    ///
    /// - Parameters:
    ///   - uplink: The local sending network quality.
    ///   - downlink: The remote receiving network quality.
    @MainActor
    func onNetworkQuality(
        uplink: RtcQualityLevel,
        downlink: RtcQualityLevel
    )

    /// Receives performance limitation or recovery events.
    ///
    /// - Parameters:
    ///   - limited: Whether performance is currently limited.
    ///   - suggestedWidth: The suggested video width in pixels.
    ///   - suggestedHeight: The suggested video height in pixels.
    ///   - suggestedFrameRate: The suggested video frame rate in fps.
    @MainActor
    func onPerformanceAlarm(
        limited: Bool,
        suggestedWidth: Int,
        suggestedHeight: Int,
        suggestedFrameRate: Int
    )
}

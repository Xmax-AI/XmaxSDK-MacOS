//
//  RealtimeNetworkQuality.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// RTC network quality levels.
public enum RealtimeNetworkQualityLevel: String, CaseIterable, Sendable {

    /// RTC has not supplied valid quality data.
    case unknown = "Unknown"

    /// Excellent network quality.
    case excellent = "Excellent"

    /// Good network quality.
    case good = "Good"

    /// Poor network quality; realtime experience may begin to degrade.
    case poor = "Poor"

    /// Very poor network quality, noticeably affecting realtime experience.
    case bad = "Bad"

    /// Extremely poor network quality; media delivery may be severely interrupted.
    case veryBad = "VeryBad"

    /// The network connection is disconnected.
    case down = "Down"
}

/// Upstream and downstream realtime session network quality.
public struct RealtimeNetworkQuality: Equatable, Sendable {

    /// The quality of local media transmission to the RTC room.
    public let uplink: RealtimeNetworkQualityLevel

    /// The quality of local media reception from the RTC room.
    public let downlink: RealtimeNetworkQualityLevel

    /// Creates an upstream and downstream network quality snapshot.
    public init(
        uplink: RealtimeNetworkQualityLevel,
        downlink: RealtimeNetworkQualityLevel
    ) {
        self.uplink = uplink
        self.downlink = downlink
    }
}

/// The realtime network quality listener.
public typealias RealtimeNetworkQualityListener =
    @MainActor @Sendable (
        RealtimeNetworkQuality
    ) -> Void

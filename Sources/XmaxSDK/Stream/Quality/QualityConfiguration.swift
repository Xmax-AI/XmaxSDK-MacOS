//
//  QualityConfiguration.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The current connection's media baseline and transport tiers in both directions.
struct QualityConfiguration: Sendable {

    /// The resolved media baseline, unchanged by quality adaptation.
    let baseline: RealtimeVideoFormat

    /// The currently applied uplink tier.
    let uplinkLevel: Int

    /// The currently submitted downlink tier.
    let downlinkLevel: Int

    /// The minimum uplink area, in pixels.
    let minimumInputPixels: Int

    /// The encoding format for the current uplink level.
    var uplink: RealtimeVideoFormat {
        QualityVideoFormat.resolve(
            baseline,
            level: uplinkLevel,
            downlink: false,
            minimumInputPixels: minimumInputPixels
        )
    }

    /// The maximum returned format for the current downlink level.
    var downlink: RealtimeVideoFormat {
        QualityVideoFormat.resolve(
            baseline,
            level: downlinkLevel,
            downlink: true
        )
    }
}

/// Upstream and downstream candidate tiers from one sample; nil leaves that direction unchanged.
struct QualityChange: Sendable {

    /// The proposed uplink tier; `nil` keeps the current tier.
    let uplink: Int?

    /// The proposed downlink tier; `nil` keeps the current tier.
    let downlink: Int?
}

//
//  QualityConfiguration.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The current connection's media baseline and transport tiers in both directions.
struct QualityConfiguration: Sendable {

    /// Media baseline
    let baseline: RealtimeVideoFormat

    /// Transport tiers
    let uplinkLevel: Int
    let downlinkLevel: Int
    let minimumInputPixels: Int

    /// Effective transport format
    var uplink: RealtimeVideoFormat {
        QualityVideoFormat.resolve(baseline, level: uplinkLevel, downlink: false, minimumInputPixels: minimumInputPixels)
    }

    var downlink: RealtimeVideoFormat {
        QualityVideoFormat.resolve(baseline, level: downlinkLevel, downlink: true)
    }
}

/// Upstream and downstream candidate tiers from one sample; nil leaves that direction unchanged.
struct QualityChange: Sendable {

    /// Candidate tiers
    let uplink: Int?
    let downlink: Int?
}

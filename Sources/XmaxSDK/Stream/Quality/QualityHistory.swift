//
//  QualityHistory.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Stores successfully committed tiers by model and direction for one hour.
struct QualityHistory {

    /// The model identifier isolating quality history.
    let model: String

    /// The preferences storing levels and timestamps.
    var defaults: UserDefaults = .standard

    /// Reads a valid tier for the model and direction from the past hour.
    ///
    /// - Parameters:
    ///   - downlink: Whether to read downstream history; `false` reads upstream.
    ///   - now: The current Unix time in seconds.
    ///
    /// - Returns: The valid historical tier, or default tier 2 for missing, expired, or invalid history.
    func read(
        downlink: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Int {
        let key = key(downlink)
        let savedAt = defaults.double(forKey: key + ".time")
        let level = defaults.integer(forKey: key)
        guard (1...5).contains(level), savedAt > 0, now >= savedAt, now - savedAt < 3600 else { return 2 }
        return level
    }

    /// Saves a successfully applied tier for the current model and direction.
    ///
    /// - Parameters:
    ///   - level: The successfully applied tier in `1...5`.
    ///   - downlink: Whether to save downstream history; `false` saves upstream.
    ///   - now: The current Unix time in seconds.
    func write(
        level: Int,
        downlink: Bool,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        defaults.set(
            level,
            forKey: key(downlink)
        )
        defaults.set(
            now,
            forKey: key(downlink) + ".time"
        )
    }

    /// Creates a history storage key scoped by model and direction.
    ///
    /// - Parameter downlink: Whether this is the downstream direction.
    ///
    /// - Returns: The storage key for the current model and direction.
    private func key(
        _ downlink: Bool
    ) -> String {
        "xmax.quality.agora.\(model).\(downlink ? "downlink" : "uplink")"
    }
}

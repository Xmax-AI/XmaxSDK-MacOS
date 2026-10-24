//
//  TrajectoryRegistry.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Registers interaction separately from video rendering, keyed by track object identity.
@MainActor
enum TrajectoryRegistry {

    /// The interaction bindings keyed by video track identifier.
    private static var bindings: [ObjectIdentifier: TrajectoryBinding] = [:]

    /// Registers an interaction binding under a remote track's object identity.
    static func register(
        _ track: RealtimeVideoTrack,
        binding: TrajectoryBinding
    ) {
        unregister(track)
        bindings[ObjectIdentifier(track)] = binding
    }

    /// Returns a track's interaction binding.
    ///
    /// - Parameter track: The remote track to find.
    ///
    /// - Returns: The registered binding, or `nil`.
    static func binding(
        for track: RealtimeVideoTrack
    ) -> TrajectoryBinding? {
        bindings[ObjectIdentifier(track)]
    }

    /// Removes and deactivates a track's interaction binding.
    ///
    /// - Parameter track: The remote track to unregister.
    static func unregister(
        _ track: RealtimeVideoTrack
    ) {
        bindings.removeValue(forKey: ObjectIdentifier(track))?.invalidate()
    }
}

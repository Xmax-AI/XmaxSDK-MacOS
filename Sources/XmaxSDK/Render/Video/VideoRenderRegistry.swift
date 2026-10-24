//
//  VideoRenderRegistry.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Stores internal bindings between realtime video tracks and underlying render capabilities.
@MainActor
enum VideoRenderRegistry {

    /// The bindings keyed by track identifier.
    private static var bindings: [ObjectIdentifier: VideoRenderBinding] = [:]

    /// Registers the render binding for a video track.
    ///
    /// - Parameters:
    ///   - track: The video track to register.
    ///   - binding: The view binding capability used by the track.
    static func register(
        _ track: RealtimeVideoTrack,
        binding: VideoRenderBinding
    ) {
        bindings[ObjectIdentifier(track)] = binding
    }

    /// Removes a track's render binding record.
    ///
    /// - Parameter track: The video track to remove.
    static func unregister(
        _ track: RealtimeVideoTrack
    ) {
        bindings.removeValue(forKey: ObjectIdentifier(track))
    }

    /// Looks up a video track's render binding.
    ///
    /// - Parameter track: The video track to look up.
    ///
    /// - Returns: The registered binding, or `nil` if absent.
    static func binding(
        for track: RealtimeVideoTrack
    ) -> VideoRenderBinding? {
        bindings[ObjectIdentifier(track)]
    }
}

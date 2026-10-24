//
//  ExternalVideoControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Manages external video bindings without owning capture resources.
protocol ExternalVideoControlling: Sendable {

    /// The active external video track, or nil when unbound.
    var currentTrack: RealtimeVideoTrack? { get }

    /// Whether the current binding supplies external audio.
    var hasAudio: Bool { get }

    /// Creates an external stream using model-validated input dimensions.
    @MainActor
    func create(
        source: any RealtimeExternalVideoSource,
        videoFormat: RealtimeVideoFormat?
    ) async throws -> RealtimeMediaStream

    /// Invalidates frame delivery, removes preview bindings, and notifies the source.
    @MainActor
    func stop() async
}

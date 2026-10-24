//
//  RealtimeConfiguration.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Business configuration for creating a realtime manager.
public struct RealtimeConfiguration: Equatable, Sendable {

    /// The model used for realtime generation.
    public let model: RealtimeModel

    /// Whether interpolation of generated remote video is enabled by default.
    public let isFrameInterpolationEnabled: Bool

    /// Creates realtime business configuration.
    public init(
        model: RealtimeModel,
        isFrameInterpolationEnabled: Bool = false
    ) {
        self.model = model
        self.isFrameInterpolationEnabled = isFrameInterpolationEnabled
    }
}

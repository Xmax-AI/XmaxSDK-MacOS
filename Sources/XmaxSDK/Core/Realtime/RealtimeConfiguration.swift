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

    /// Whether uplink and downlink quality levels adapt automatically.
    ///
    /// When disabled, each connection starts at L1. Manual changes remain available.
    public let isAdaptiveQualityEnabled: Bool

    /// The Core Audio input device UID used when microphone capture is enabled.
    /// `nil` follows the system default input without changing system settings.
    public let microphoneDeviceID: String?

    /// Creates realtime business configuration.
    public init(
        model: RealtimeModel,
        isFrameInterpolationEnabled: Bool = true,
        isAdaptiveQualityEnabled: Bool = true,
        microphoneDeviceID: String? = nil
    ) {
        self.model = model
        self.isFrameInterpolationEnabled = isFrameInterpolationEnabled
        self.isAdaptiveQualityEnabled = isAdaptiveQualityEnabled
        self.microphoneDeviceID = microphoneDeviceID
    }
}

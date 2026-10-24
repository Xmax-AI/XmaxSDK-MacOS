//
//  RealtimeModel.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import CoreGraphics

/// Realtime generation models currently supported by the SDK.
public enum RealtimeModel: String, CaseIterable, Sendable {

    /// The domestic Agora realtime generation model.
    case x2_1_1_preview_cn = "x2.1.1-preview-cn"

    /// The overseas Agora realtime generation model.
    case x2_1_1_preview_us = "x2.1.1-preview-us"

    /// The model display name.
    public var displayName: String {
        switch self {
        case .x2_1_1_preview_cn: "X2.1.1-preview-cn"
        case .x2_1_1_preview_us: "X2.1.1-preview-us"
        }
    }

    /// The session API URL for this model.
    var apiBaseURL: URL {
        switch self {
        case .x2_1_1_preview_cn: URL(string: "https://cloud.xmax.22duck.cn/open/api/v1")!
        case .x2_1_1_preview_us: URL(string: "https://api.xmax.ai/open/api/v1")!
        }
    }

    /// Supported generation resolution buckets; camera input must match exactly.
    /// Images and videos retain their aspect ratio and use the closest generation canvas.
    /// An empty array permits calculated canvas dimensions based on pixel area limits and alignment rules.
    public var resolutionBuckets: [CGSize] {
        [CGSize(width: 1024, height: 1920), CGSize(width: 1920, height: 1024)]
    }

    /// The minimum local media and uplink pixel area; also limits variable generation canvases.
    public var minimumInputPixels: Int { 200000 }

    /// The maximum local media frame pixel area; also limits the generation canvas when no resolution buckets are defined.
    public var maximumInputPixels: Int { 2100000 }

    /// The pixel alignment multiple for input dimensions; used only when no resolution buckets are defined.
    public var inputSizeAlignment: Int { 32 }

    /// The frame rate for image and video output and default camera configuration.
    public var defaultFrameRate: Int { 30 }

    /// The default video format for camera capture.
    public var defaultCameraVideoFormat: RealtimeVideoFormat {
        RealtimeVideoFormat(width: 1920, height: 1024, fps: defaultFrameRate)
    }
}

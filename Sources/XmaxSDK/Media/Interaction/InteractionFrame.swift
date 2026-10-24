//
//  InteractionFrame.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics

/// An interaction sample captured from a render viewport.
struct InteractionFrame: Sendable {

    /// The sampled pointer positions relative to the viewport.
    let points: [CGPoint]

    /// The viewport dimensions, in points.
    let viewportSize: CGSize

    /// The view's video content mode.
    let contentMode: VideoContentMode

    /// The displayed media dimensions used to map viewport coordinates.
    var displayedVideoSize: CGSize? = nil
}

extension RealtimeVideoFormat {

    /// The video format dimensions, in pixels.
    var size: CGSize {
        CGSize(
            width: width,
            height: height
        )
    }
}

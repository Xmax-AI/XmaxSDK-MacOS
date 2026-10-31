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

    /// Whether the sampled viewport horizontally mirrors the media pixels.
    let isMirrored: Bool

    /// Captures the display geometry and mirroring used by these pointer samples.
    init(
        points: [CGPoint],
        viewportSize: CGSize,
        contentMode: VideoContentMode,
        isMirrored: Bool = false
    ) {
        self.points = points
        self.viewportSize = viewportSize
        self.contentMode = contentMode
        self.isMirrored = isMirrored
    }
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

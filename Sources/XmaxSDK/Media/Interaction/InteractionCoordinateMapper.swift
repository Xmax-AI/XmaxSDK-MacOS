//
//  InteractionCoordinateMapper.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics

/// Maps render viewport coordinates to normalized coordinates in a fixed media reference.
enum InteractionCoordinateMapper {

    /// Calculates the video display rectangle for the specified viewport scaling mode.
    ///
    /// - Parameters:
    ///   - viewportSize: The render viewport dimensions in points.
    ///   - videoSize: The video content dimensions in pixels.
    ///   - contentMode: How video fills or fits the viewport.
    ///
    /// - Returns: The video display rectangle in viewport coordinates; `nil` for invalid dimensions or scaling.
    static func displayedFrame(
        viewportSize: CGSize,
        videoSize: CGSize,
        contentMode: VideoContentMode
    ) -> CGRect? {
        guard viewportSize.width.isFinite, viewportSize.height.isFinite,
            videoSize.width.isFinite, videoSize.height.isFinite,
            viewportSize.width > 0,
            viewportSize.height > 0,
            videoSize.width > 0,
            videoSize.height > 0
        else {
            return nil
        }

        let widthScale = viewportSize.width / videoSize.width
        let heightScale = viewportSize.height / videoSize.height
        let scale =
            contentMode == .fill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        guard scale.isFinite, scale > 0 else { return nil }

        let displayedSize = CGSize(
            width: videoSize.width * scale,
            height: videoSize.height * scale
        )
        return CGRect(
            x: (viewportSize.width - displayedSize.width) / 2,
            y: (viewportSize.height - displayedSize.height) / 2,
            width: displayedSize.width,
            height: displayedSize.height
        )
    }

    /// Calculates relative media coordinates from a pointer position and the actual video display rectangle.
    ///
    /// - Parameters:
    ///   - point: The pointer position in the viewport.
    ///   - viewportSize: The render viewport dimensions in points.
    ///   - displayedVideoSize: The displayed frame pixel dimensions used to determine the video display rectangle.
    ///   - mediaSize: The size-limited, aligned media dimensions used as the normalization reference.
    ///   - contentMode: The video scaling and cropping mode.
    ///
    /// - Returns: Media-normalized coordinates in `[0, 1]`; `nil` for invalid input or taps in fit-mode margins.
    static func map(
        _ point: CGPoint,
        viewportSize: CGSize,
        displayedVideoSize: CGSize,
        mediaSize: CGSize,
        contentMode: VideoContentMode
    ) -> RealtimePoint? {
        guard point.x.isFinite,
            point.y.isFinite,
            mediaSize.width.isFinite, mediaSize.height.isFinite,
            mediaSize.width >= 1, mediaSize.height >= 1,
            let displayedFrame = displayedFrame(
                viewportSize: viewportSize,
                videoSize: displayedVideoSize,
                contentMode: contentMode
            )
        else {
            return nil
        }
        if contentMode == .fit, !displayedFrame.contains(point) {
            return nil
        }

        let normalizedX = (point.x - displayedFrame.minX) / displayedFrame.width
        let normalizedY = (point.y - displayedFrame.minY) / displayedFrame.height
        return RealtimePoint(
            x: min(max(normalizedX, 0), 1),
            y: min(max(normalizedY, 0), 1)
        )
    }
}

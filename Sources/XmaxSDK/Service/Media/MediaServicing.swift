//
//  MediaServicing.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics

/// Defines business rules for local media, generation canvas, return dimensions, and platform capabilities.
public protocol MediaServicing: Sendable {

    /// The realtime model used by the media rules.
    var model: RealtimeModel { get }

    /// Calculates local frame dimensions and validates camera resolution buckets.
    ///
    /// - Parameters:
    ///   - size: Requested camera dimensions or oriented integer-pixel image or video dimensions.
    ///   - source: The media source; only camera inputs must match configured resolution buckets.
    /// - Returns: Dimensions aligned to four pixels within model minimum and maximum pixel areas, preferring exact aspect ratio.
    /// - Throws: An error on invalid dimensions, unmatched input resolution buckets, or no valid output dimensions.
    func resolveMediaSize(_ size: CGSize, source: RealtimeMediaSource) throws -> CGSize

    /// Resolves the generation canvas separately from local media dimensions.
    func resolveGenerationSize(_ size: CGSize) throws -> CGSize

    /// Calculates final return dimensions from tier limits and optional interpolation constraints.
    ///
    /// - Parameters:
    ///   - sourceSize: The original integer-pixel media dimensions defining aspect ratio and no-upscaling bounds.
    ///   - maximumSize: The downstream tier dimension limits, potentially containing fractional pixels.
    ///   - frameInterpolationEnabled: Whether to additionally limit total pixels to 900000; does not check device capabilities.
    /// - Returns: Dimensions within limits and aligned to four pixels; prefers exact aspect ratio, otherwise rounds each side down.
    /// - Throws: `XmaxError` for invalid dimensions or limits that cannot accommodate at least 4 × 4 pixels.
    func resolveTargetSize(
        _ sourceSize: CGSize,
        maximumSize: CGSize,
        frameInterpolationEnabled: Bool
    ) throws -> CGSize

    /// Checks device interpolation support for the specified video resolution.
    ///
    /// - Parameter size: The received video resolution used for interpolation.
    /// - Returns: `true` if the system, device, and video format all support interpolation.
    func supportsFrameInterpolation(for size: CGSize) -> Bool
}

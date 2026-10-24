//
//  FrameInterpolationManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia

/// Defines internal single-frame interpolation processor capabilities.
protocol FrameInterpolationManaging: AnyObject, Sendable {

    /// Checks whether the processor still matches the input frame format.
    ///
    /// - Parameter frame: The video frame to compare.
    ///
    /// - Returns: `true` if dimensions and pixel format both match.
    func matches(
        _ frame: RealtimeVideoFrame
    ) -> Bool

    /// Generates an intermediate frame between the previous and current frames.
    ///
    /// - Parameters:
    ///   - frame: The current decoded video frame.
    ///   - sourceDuration: The display duration of the current source frame.
    ///
    /// - Returns: the original first frame; subsequent calls return an intermediate frame and the current original
    ///   frame.
    ///
    /// - Throws: An error on pixel buffer preparation or VideoToolbox processing failure.
    func process(
        _ frame: RealtimeVideoFrame,
        sourceDuration: CMTime
    ) async throws -> [RealtimeVideoFrame]

    /// Ends interpolation, releases frame history, and rejects further processing requests.
    func close() async
}

//
//  InteractionControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Manages trajectory interaction input during generation.
protocol InteractionControlling: Sendable {

    /// Starts receiving pointer trajectories for the current generation task.
    ///
    /// - Parameters:
    ///   - taskID: The current generation task identifier.
    ///   - videoFormat: The fixed local media format used as the normalization reference.
    func startInteraction(
        taskID: String,
        videoFormat: RealtimeVideoFormat
    ) async

    /// Stops receiving trajectories and clears the current task.
    func stopInteraction() async

    /// Submits a pointer trajectory.
    ///
    /// - Parameter frame: The trajectory and display dimensions captured from the current view.
    func submitInteraction(
        _ frame: InteractionFrame
    ) async
}

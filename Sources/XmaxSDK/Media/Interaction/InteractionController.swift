//
//  InteractionController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Asynchronously receives a generation task identifier and media-normalized trajectory coordinates.
typealias InteractionListener =
    @Sendable (
        _ taskID: String,
        _ points: [RealtimePoint]
    ) async throws -> Void

/// Maps pointer positions from the render container to normalized coordinates in a fixed media reference and sends
/// them.
actor InteractionController: InteractionControlling {

    /// Stores interaction coordinate mapping for the current generation task.
    private struct ActiveInteraction {

        /// The generation task receiving interactions.
        let taskID: String

        /// The local media dimensions used to normalize interaction coordinates.
        let videoFormat: RealtimeVideoFormat
    }

    /// The asynchronous task and normalized coordinate handler.
    private let listener: InteractionListener

    /// The active interaction configuration.
    private var activeInteraction: ActiveInteraction?

    /// The latest unsent trajectory.
    private var pendingPoints: [RealtimePoint]?

    /// The task serializing trajectory sends.
    private var drainTask: Task<Void, Never>?

    /// The revision rejecting stale trajectory tasks.
    private var drainGeneration = 0

    /// Creates an interaction controller forwarding trajectory coordinates to signaling.
    ///
    /// - Parameter listener: The asynchronous callback receiving task identifiers and media-normalized coordinates.
    init(
        listener: @escaping InteractionListener = { _, _ in }
    ) {
        self.listener = listener
    }

    /// Cancels pending trajectory send tasks.
    deinit {
        drainTask?.cancel()
    }

    /// Starts receiving pointer trajectories for the current generation task.
    ///
    /// - Parameters:
    ///   - taskID: The current generation task identifier.
    ///   - videoFormat: The fixed local media format used as the normalization reference.
    func startInteraction(
        taskID: String,
        videoFormat: RealtimeVideoFormat
    ) {
        cancelPendingFrames()
        activeInteraction = ActiveInteraction(
            taskID: taskID,
            videoFormat: videoFormat
        )
    }

    /// Stops receiving trajectories and clears the current task.
    func stopInteraction() {
        activeInteraction = nil
        cancelPendingFrames()
    }

    /// Submits a pointer trajectory.
    ///
    /// - Parameter frame: The trajectory and display dimensions captured from the current view.
    func submitInteraction(
        _ frame: InteractionFrame
    ) {
        guard let activeInteraction,
            !frame.points.isEmpty
        else {
            return
        }

        let mediaSize = activeInteraction.videoFormat.size
        let displayedVideoSize = frame.displayedVideoSize ?? mediaSize
        let points = frame.points.compactMap {
            InteractionCoordinateMapper.map(
                $0,
                viewportSize: frame.viewportSize,
                displayedVideoSize: displayedVideoSize,
                mediaSize: mediaSize,
                contentMode: frame.contentMode
            )
        }
        guard !points.isEmpty else { return }

        pendingPoints = points
        guard drainTask == nil else { return }
        let generation = drainGeneration
        drainTask = Task { [weak self] in
            await self?.drainPendingFrames(generation: generation)
        }
    }
}

private extension InteractionController {

    /// Invalidates the current send task and clears pending trajectories.
    func cancelPendingFrames() {
        drainGeneration += 1
        pendingPoints = nil
        drainTask?.cancel()
        drainTask = nil
    }

    /// Continuously sends the latest trajectory samples and rejects obsolete send loops.
    ///
    /// - Parameter generation: The current send loop version identifier.
    func drainPendingFrames(
        generation: Int
    ) async {
        while !Task.isCancelled,
            generation == drainGeneration,
            let interaction = activeInteraction,
            let points = pendingPoints
        {
            pendingPoints = nil
            do {
                try await listener(
                    interaction.taskID,
                    points
                )
            } catch is CancellationError {
                break
            } catch {
                XmaxLogger.interaction.warn(
                    message: "发送交互轨迹失败，已丢弃当前采样帧 " + "(Failed to Send Interaction Trajectory; Current Sample Dropped)\n"
                        + "└─ \(XmaxLogger.localized("原因：", "Reason: "))" + (error as NSError).localizedDescription
                )
            }
        }
        guard generation == drainGeneration else { return }
        drainTask = nil

        if activeInteraction != nil, pendingPoints != nil {
            drainTask = Task { [weak self] in
                await self?.drainPendingFrames(generation: generation)
            }
        }
    }
}

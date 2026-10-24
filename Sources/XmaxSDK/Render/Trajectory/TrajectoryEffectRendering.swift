//
//  TrajectoryEffectRendering.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit

/// A stable identifier for one pointer trajectory.
public struct TrajectoryID: Hashable, Sendable {

    /// The unique value identifying this trajectory.
    let rawValue: UUID

    /// Creates a trajectory identifier.
    init(
        rawValue: UUID = UUID()
    ) {
        self.rawValue = rawValue
    }
}

/// A sampled pointer position supplied to a trajectory effect renderer.
public struct TrajectoryPoint: Sendable {

    /// The trajectory containing this sample.
    public let id: TrajectoryID

    /// The pointer position in overlay coordinates, in points.
    public let location: CGPoint

    /// The pointer coordinates normalized to the complete displayed media rectangle.
    public let normalizedLocation: CGPoint

    /// The monotonic sample time, in seconds.
    public let timestamp: TimeInterval

    /// Creates a pointer sample for trajectory rendering.
    init(
        id: TrajectoryID,
        location: CGPoint,
        normalizedLocation: CGPoint,
        timestamp: TimeInterval
    ) {
        self.id = id
        self.location = location
        self.normalizedLocation = normalizedLocation
        self.timestamp = timestamp
    }
}

/// A renderer for custom pointer trajectory visuals.
///
/// XmaxSDK owns pointer collection, coordinate mapping, sampling, and signaling. Replacing the renderer changes only
/// the displayed effect.
@MainActor
public protocol TrajectoryEffectRendering: AnyObject {

    /// The effect view installed above the video viewport.
    var view: NSView { get }

    /// Starts drawing the supplied trajectories.
    ///
    /// - Parameter points: The initial pointer samples.
    func renderBegan(
        _ points: [TrajectoryPoint]
    )

    /// Updates the active trajectory positions.
    ///
    /// - Parameter points: The latest pointer samples.
    func renderMoved(
        _ points: [TrajectoryPoint]
    )

    /// Ends active drawing for the specified trajectories.
    ///
    /// - Parameter identifiers: The trajectories to finish.
    func renderEnded(
        _ identifiers: [TrajectoryID]
    )

    /// Clears all trajectory effects and animation resources.
    func reset()
}

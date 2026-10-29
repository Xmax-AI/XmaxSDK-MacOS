//
//  XmaxRealtimeVideo.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import SwiftUI

/// A SwiftUI view rendering one local or remote realtime video track.
@MainActor
public struct XmaxRealtimeVideo: NSViewRepresentable {

    /// The displayed video track.
    public let track: RealtimeVideoTrack?

    /// The video content display mode in its container.
    public let videoContentMode: VideoContentMode

    /// The first-frame fade-in duration, in seconds; zero disables animation by default.
    public let fadeInDuration: TimeInterval

    /// Whether a ready remote track accepts pointer trajectories.
    public let isInteractionEnabled: Bool

    /// Whether to mirror video; interaction coordinates remain in displayed orientation.
    public let isMirrored: Bool

    /// Custom trajectory visuals; nil uses the built-in green glow.
    public let trajectoryRenderer: (any TrajectoryEffectRendering)?

    /// Creates a SwiftUI video rendering component.
    public init(
        track: RealtimeVideoTrack?,
        videoContentMode: VideoContentMode = .fill,
        fadeInDuration: TimeInterval = 0,
        isInteractionEnabled: Bool = true,
        isMirrored: Bool = false,
        trajectoryRenderer: (any TrajectoryEffectRendering)? = nil
    ) {
        self.track = track
        self.videoContentMode = videoContentMode
        self.fadeInDuration = fadeInDuration
        self.isInteractionEnabled = isInteractionEnabled
        self.isMirrored = isMirrored
        self.trajectoryRenderer = trajectoryRenderer
    }

    /// Creates an AppKit view hosting SwiftUI video content.
    ///
    /// - Parameter context: The SwiftUI view creation context.
    ///
    /// - Returns: The SDK video view configured for the current track.
    public func makeNSView(
        context: Context
    ) -> XmaxRealtimeVideoView {
        let view = XmaxRealtimeVideoView(
            track: track,
            videoContentMode: videoContentMode,
            fadeInDuration: fadeInDuration
        )
        view.isInteractionEnabled = isInteractionEnabled
        view.isMirrored = isMirrored
        view.trajectoryRenderer = trajectoryRenderer
        return view
    }

    /// Synchronizes track and display configuration changes to the AppKit view.
    ///
    /// - Parameters:
    ///   - view: The SDK video view to update.
    ///   - context: The SwiftUI view update context.
    public func updateNSView(
        _ view: XmaxRealtimeVideoView,
        context: Context
    ) {
        view.fadeInDuration = fadeInDuration
        view.videoContentMode = videoContentMode
        view.isInteractionEnabled = isInteractionEnabled
        view.isMirrored = isMirrored
        view.trajectoryRenderer = trajectoryRenderer
        view.track = track
    }

    /// Unbinds video tracks when SwiftUI removes the view.
    ///
    /// - Parameters:
    ///   - view: The SDK video view being removed.
    ///   - coordinator: The stateless SwiftUI coordinator.
    public static func dismantleNSView(
        _ view: XmaxRealtimeVideoView,
        coordinator: Void
    ) {
        view.track = nil
    }
}

//
//  XmaxRealtimeDualVideo.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import SwiftUI

/// A SwiftUI view stacking remote generation above a continuously running local preview.
///
/// Both video views share the same bounds. The remote view fades in after its first frame is submitted;
/// clearing `remoteTrack` immediately reveals the local preview again.
@MainActor
public struct XmaxRealtimeDualVideo: NSViewRepresentable {

    /// The displayed local video track.
    public let localTrack: RealtimeVideoTrack?

    /// The displayed remote generation video track.
    public let remoteTrack: RealtimeVideoTrack?

    /// The video content display mode in its container.
    public let videoContentMode: VideoContentMode

    /// The remote video's fade-in duration, in seconds. The default is 0.3; zero disables animation.
    public let remoteVideoFadeInDuration: TimeInterval

    /// Whether a ready remote track accepts pointer trajectories.
    public let isInteractionEnabled: Bool

    /// Whether to mirror video; interaction coordinates remain in displayed orientation.
    public let isMirrored: Bool

    /// Custom trajectory visuals; nil uses the built-in green glow.
    public let trajectoryRenderer: (any TrajectoryEffectRendering)?

    /// Creates a SwiftUI dual video component with local preview beneath remote generation.
    public init(
        localTrack: RealtimeVideoTrack?,
        remoteTrack: RealtimeVideoTrack?,
        videoContentMode: VideoContentMode = .fill,
        remoteVideoFadeInDuration: TimeInterval = 0.3,
        isInteractionEnabled: Bool = true,
        isMirrored: Bool = false,
        trajectoryRenderer: (any TrajectoryEffectRendering)? = nil
    ) {
        self.localTrack = localTrack
        self.remoteTrack = remoteTrack
        self.videoContentMode = videoContentMode
        self.remoteVideoFadeInDuration = remoteVideoFadeInDuration
        self.isInteractionEnabled = isInteractionEnabled
        self.isMirrored = isMirrored
        self.trajectoryRenderer = trajectoryRenderer
    }

    /// Creates an AppKit view hosting SwiftUI video content.
    ///
    /// - Parameter context: The SwiftUI view creation context.
    ///
    /// - Returns: The SDK dual video view configured with local and remote tracks.
    public func makeNSView(
        context: Context
    ) -> XmaxRealtimeDualVideoView {
        let view = XmaxRealtimeDualVideoView(
            localTrack: localTrack,
            remoteTrack: remoteTrack,
            videoContentMode: videoContentMode,
            remoteVideoFadeInDuration: remoteVideoFadeInDuration,
            isInteractionEnabled: isInteractionEnabled
        )
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
        _ view: XmaxRealtimeDualVideoView,
        context: Context
    ) {
        view.videoContentMode = videoContentMode
        view.remoteVideoFadeInDuration = remoteVideoFadeInDuration
        view.isInteractionEnabled = isInteractionEnabled
        view.isMirrored = isMirrored
        view.trajectoryRenderer = trajectoryRenderer
        view.localTrack = localTrack
        view.remoteTrack = remoteTrack
    }

    /// Unbinds video tracks when SwiftUI removes the view.
    ///
    /// - Parameters:
    ///   - view: The SDK video view being removed.
    ///   - coordinator: The stateless SwiftUI coordinator.
    public static func dismantleNSView(
        _ view: XmaxRealtimeDualVideoView,
        coordinator: Void
    ) {
        view.localTrack = nil
        view.remoteTrack = nil
    }
}

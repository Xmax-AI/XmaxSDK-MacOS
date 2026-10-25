//
//  XmaxRealtimeVideoView.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit

/// Continuously previews local video and overlays generation after the first remote frame is submitted.
@MainActor
public final class XmaxRealtimeVideoView: NSView {

    /// The local camera video track.
    public var localTrack: RealtimeVideoTrack? {
        didSet { localVideoView.track = localTrack }
    }

    /// The remote generated track; nil immediately restores local preview.
    public var remoteTrack: RealtimeVideoTrack? {
        didSet {
            guard oldValue !== remoteTrack else { return }
            updateRemoteTrack()
        }
    }

    /// The shared local and remote video scaling and cropping mode.
    public var videoContentMode: VideoContentMode = .fill {
        didSet {
            localVideoView.videoContentMode = videoContentMode
            remoteVideoView.videoContentMode = videoContentMode
        }
    }

    /// Enables trajectories on the generated result only.
    public var isInteractionEnabled: Bool {
        get { remoteVideoView.isInteractionEnabled }
        set { remoteVideoView.isInteractionEnabled = newValue }
    }

    /// Mirrors the generated result; interaction coordinates follow the displayed pointer.
    public var isMirrored: Bool {
        get { remoteVideoView.isMirrored }
        set { remoteVideoView.isMirrored = newValue }
    }

    /// Overrides result trajectory visuals; nil selects the built-in effect.
    public var trajectoryRenderer: (any TrajectoryEffectRendering)? {
        get { remoteVideoView.trajectoryRenderer }
        set { remoteVideoView.trajectoryRenderer = newValue }
    }

    /// The video view retaining local preview beneath the result.
    private let localVideoView = XmaxVideoView()

    /// The video view displaying the generated result.
    private let remoteVideoView = XmaxVideoView()

    /// Creates a realtime video container.
    ///
    /// - Parameters:
    ///   - localTrack: The continuously previewed local track.
    ///   - remoteTrack: The generation result track displayed as an overlay.
    ///   - videoContentMode: The video content display mode.
    ///   - isInteractionEnabled: Whether to accept pointer trajectories on the generated result.
    public init(
        localTrack: RealtimeVideoTrack? = nil,
        remoteTrack: RealtimeVideoTrack? = nil,
        videoContentMode: VideoContentMode = .fill,
        isInteractionEnabled: Bool = true
    ) {
        self.localTrack = localTrack
        self.remoteTrack = remoteTrack
        self.videoContentMode = videoContentMode
        super.init(frame: .zero)
        self.isInteractionEnabled = isInteractionEnabled
        configureView()
    }

    /// Creates a realtime video container with the specified frame.
    ///
    /// - Parameter frame: The initial view frame.
    public override init(
        frame: CGRect
    ) {
        super.init(frame: frame)
        configureView()
    }

    /// Restores a realtime video container from an Interface Builder archive.
    ///
    /// - Parameter coder: The view archive decoder.
    public required init?(
        coder: NSCoder
    ) {
        super.init(coder: coder)
        configureView()
    }

    /// Synchronizes both video subview layouts.
    public override func layout() {
        super.layout()
        localVideoView.frame = bounds
        remoteVideoView.frame = bounds
    }

    /// Installs local preview and remote result layers.
    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        addSubview(localVideoView)
        addSubview(remoteVideoView)
        localVideoView.videoContentMode = videoContentMode
        remoteVideoView.videoContentMode = videoContentMode
        localVideoView.track = localTrack
        updateRemoteTrack()
    }

    /// Waits for the new remote track's first frame to avoid blank output during switching.
    private func updateRemoteTrack() {
        remoteVideoView.frameDisplayHandler = nil
        remoteVideoView.track = nil
        remoteVideoView.isHidden = true
        guard let remoteTrack else { return }
        remoteVideoView.frameDisplayHandler = { [weak self, weak remoteTrack] in
            guard let self, self.remoteTrack === remoteTrack else { return }
            remoteVideoView.isHidden = false
            remoteVideoView.frameDisplayHandler = nil
        }
        remoteVideoView.track = remoteTrack
    }
}

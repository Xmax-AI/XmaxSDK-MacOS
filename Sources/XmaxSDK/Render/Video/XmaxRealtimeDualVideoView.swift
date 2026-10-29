//
//  XmaxRealtimeDualVideoView.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import QuartzCore

/// An AppKit view stacking remote generation above a continuously running local preview.
///
/// Both video views share the same bounds. The remote view fades in after its first frame is submitted;
/// clearing `remoteTrack` immediately reveals the local preview again.
@MainActor
public final class XmaxRealtimeDualVideoView: NSView {

    /// The local video track kept running beneath the generated result.
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

    /// The remote video's fade-in duration, in seconds. The default is 0.3.
    ///
    /// Zero, negative, or nonfinite values disable the animation. Changes apply to the next fade-in.
    public var remoteVideoFadeInDuration: TimeInterval = 0.3

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

    /// The video view retaining local preview beneath the result without an independent fade-in.
    private let localVideoView = XmaxRealtimeVideoView(fadeInDuration: 0)

    /// The result video view whose fade-in is owned by this container.
    private let remoteVideoView = XmaxRealtimeVideoView(fadeInDuration: 0)

    /// Creates a dual video container with local preview beneath remote generation.
    ///
    /// - Parameters:
    ///   - localTrack: The continuously previewed local track.
    ///   - remoteTrack: The generation result track displayed as an overlay.
    ///   - videoContentMode: The video content display mode.
    ///   - remoteVideoFadeInDuration: The remote fade-in duration, in seconds; zero disables animation.
    ///   - isInteractionEnabled: Whether to accept pointer trajectories on the generated result.
    public init(
        localTrack: RealtimeVideoTrack? = nil,
        remoteTrack: RealtimeVideoTrack? = nil,
        videoContentMode: VideoContentMode = .fill,
        remoteVideoFadeInDuration: TimeInterval = 0.3,
        isInteractionEnabled: Bool = true
    ) {
        self.localTrack = localTrack
        self.remoteTrack = remoteTrack
        self.videoContentMode = videoContentMode
        self.remoteVideoFadeInDuration = remoteVideoFadeInDuration
        super.init(frame: .zero)
        self.isInteractionEnabled = isInteractionEnabled
        configureView()
    }

    /// Creates a dual video container with the specified frame.
    ///
    /// - Parameter frame: The initial view frame.
    public override init(
        frame: CGRect
    ) {
        super.init(frame: frame)
        configureView()
    }

    /// Restores a dual video container from an Interface Builder archive.
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
        remoteVideoView.layer?.removeAllAnimations()
        remoteVideoView.alphaValue = 0
        remoteVideoView.isHidden = true
        remoteVideoView.track = nil
        guard let remoteTrack else { return }
        remoteVideoView.frameDisplayHandler = { [weak self, weak remoteTrack] in
            guard let self, self.remoteTrack === remoteTrack else { return }
            showRemoteVideo()
        }
        remoteVideoView.track = remoteTrack
    }

    /// Displays the first remote frame, optionally fading it in over the local preview.
    private func showRemoteVideo() {
        remoteVideoView.frameDisplayHandler = nil
        guard remoteVideoView.isHidden || remoteVideoView.alphaValue < 1 else { return }
        remoteVideoView.layer?.removeAllAnimations()
        remoteVideoView.isHidden = false
        remoteVideoView.alphaValue = 1
        let duration = remoteVideoFadeInDuration
        guard duration.isFinite, duration > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        remoteVideoView.layer?.add(
            fade,
            forKey: "remoteVideoFadeIn"
        )
    }
}

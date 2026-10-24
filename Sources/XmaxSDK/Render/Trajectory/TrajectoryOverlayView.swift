//
//  TrajectoryOverlayView.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit

/// Collects primary-button drags; visual rendering and 30 Hz network sampling remain independent.
@MainActor
final class TrajectoryOverlayView: NSView {

    /// The binding delivering samples to media interactions.
    private weak var binding: TrajectoryBinding?

    /// Whether the generation binding permits interaction.
    private var enabled = false

    /// Whether the hosting video view requests interaction.
    private var requested = true

    /// The display mirroring state used to cancel gestures when presentation changes.
    private var mirrored = false

    /// The fitting or cropping mode used for coordinate mapping.
    private var contentMode: VideoContentMode = .fill

    /// The current media dimensions used for coordinate mapping.
    private var displayedSize: CGSize?

    /// The viewport size used to detect gesture-invalidating layout changes.
    private var previousViewport: CGSize = .zero

    /// The current primary-button gesture position and identity.
    private var activePoint: TrajectoryPoint?

    /// The timer sampling the active gesture for network submission.
    private var sampler: Timer?

    /// The trajectory effect renderer.
    private var renderer: any TrajectoryEffectRendering

    /// Whether view coordinates increase downward to match video pixels.
    override var isFlipped: Bool { true }

    /// Whether the overlay paints an opaque background.
    override var isOpaque: Bool { false }

    /// Whether this view accepts keyboard cancellation while dragging.
    override var acceptsFirstResponder: Bool { true }

    /// Accepts the initial pointer press when the window is inactive.
    override func acceptsFirstMouse(
        for event: NSEvent?
    ) -> Bool { true }

    /// Creates a trajectory overlay and observes application and window focus loss.
    init(
        renderer: any TrajectoryEffectRendering
    ) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        installRenderer()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cancelFromNotification),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResigned(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }

    /// Marks archive initialization as unavailable; create this view programmatically.
    @available(*, unavailable)
    required init?(
        coder: NSCoder
    ) { fatalError("init(coder:) has not been implemented") }

    /// Stops sampling and removes focus-loss observers.
    isolated deinit {
        sampler?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// Replaces the generation binding and cancels the current gesture.
    func setBinding(
        _ binding: TrajectoryBinding?,
        enabled: Bool
    ) {
        cancelInteraction()
        self.binding = binding
        self.enabled = enabled
    }

    /// Updates coordinate mapping and input availability, cancelling the current gesture on changes.
    func configure(
        contentMode: VideoContentMode,
        mirrored: Bool,
        requested: Bool,
        displayedSize: CGSize?
    ) {
        guard
            self.contentMode != contentMode || self.mirrored != mirrored || self.requested != requested
                || self.displayedSize != displayedSize
        else { return }
        cancelInteraction()
        self.contentMode = contentMode
        self.mirrored = mirrored
        self.requested = requested
        self.displayedSize = displayedSize
    }

    /// Replaces trajectory visuals and resets the current gesture.
    func setRenderer(
        _ renderer: any TrajectoryEffectRendering
    ) {
        guard self.renderer !== renderer else { return }
        cancelInteraction()
        self.renderer.view.removeFromSuperview()
        self.renderer = renderer
        installRenderer()
    }

    /// Fits the effect renderer to the viewport and cancels gestures after resizing.
    override func layout() {
        super.layout()
        if previousViewport != bounds.size {
            cancelInteraction()
            previousViewport = bounds.size
        }
        renderer.view.frame = bounds
    }

    /// Cancels interaction when the overlay leaves its window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelInteraction() }
    }

    /// Cancels interaction when the overlay becomes hidden.
    override func viewDidHide() {
        super.viewDidHide()
        cancelInteraction()
    }

    /// Accepts pointer input only inside the visible, interactive video region.
    override func hitTest(
        _ point: NSPoint
    ) -> NSView? {
        let local = convert(
            point,
            from: superview
        )
        guard available, interactionFrame?.contains(local) == true else { return nil }
        // Custom effect views cannot intercept the SDK's pointer collection.
        return self
    }

    /// Starts a primary-button gesture inside the visible video and begins sampling.
    override func mouseDown(
        with event: NSEvent
    ) {
        guard available, event.buttonNumber == 0,
            let point = makePoint(
                event,
                id: TrajectoryID(),
                clamp: false
            )
        else { return }
        window?.makeFirstResponder(self)
        cancelInteraction()
        activePoint = point
        renderer.renderBegan([point])
        sample()
        let timer = Timer(
            timeInterval: 1.0 / 30,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sampler = timer
        RunLoop.main.add(
            timer,
            forMode: .common
        )
    }

    /// Updates the active gesture, clamping its position to the visible video.
    override func mouseDragged(
        with event: NSEvent
    ) {
        guard available, let previous = activePoint,
            let point = makePoint(
                event,
                id: previous.id,
                clamp: true
            )
        else { return }
        activePoint = point
        renderer.renderMoved([point])
    }

    /// Submits the final gesture position and stops sampling.
    override func mouseUp(
        with event: NSEvent
    ) {
        guard let previous = activePoint else { return }
        if let point = makePoint(
            event,
            id: previous.id,
            clamp: true
        ) {
            activePoint = point
            renderer.renderMoved([point])
            sample()
        }
        renderer.renderEnded([previous.id])
        activePoint = nil
        stopSampling()
    }

    /// Cancels the current gesture in response to keyboard cancellation.
    override func cancelOperation(
        _ sender: Any?
    ) { cancelInteraction() }

    /// Ends the active gesture, stops sampling, and clears trajectory visuals.
    func cancelInteraction() {
        if let activePoint { renderer.renderEnded([activePoint.id]) }
        activePoint = nil
        stopSampling()
        renderer.reset()
    }

    /// Whether this viewport can accept interaction for the current binding.
    private var available: Bool {
        enabled && requested && binding != nil && window != nil && !isHiddenOrHasHiddenAncestor
            && interactionFrame != nil
    }

    /// The complete displayed video rectangle before viewport clipping.
    private var displayedFrame: CGRect? {
        guard let displayedSize else { return nil }
        return InteractionCoordinateMapper.displayedFrame(
            viewportSize: bounds.size,
            videoSize: displayedSize,
            contentMode: contentMode
        )
    }

    /// The visible intersection of the video rectangle and viewport.
    private var interactionFrame: CGRect? {
        guard let frame = displayedFrame?.intersection(bounds), !frame.isEmpty, !frame.isNull else { return nil }
        return frame
    }

    /// Converts a window event into viewport and normalized media coordinates.
    private func makePoint(
        _ event: NSEvent,
        id: TrajectoryID,
        clamp: Bool
    ) -> TrajectoryPoint? {
        guard let area = interactionFrame, let media = displayedFrame else { return nil }
        var location = convert(
            event.locationInWindow,
            from: nil
        )
        guard location.x.isFinite, location.y.isFinite else { return nil }
        if !clamp && !area.contains(location) { return nil }
        // Keep samples just inside max edges, which CGRect.contains otherwise excludes in fit mode.
        location.x = min(max(location.x, area.minX), area.maxX.nextDown)
        location.y = min(max(location.y, area.minY), area.maxY.nextDown)
        let x = (location.x - media.minX) / media.width
        return TrajectoryPoint(
            id: id,
            location: location,
            normalizedLocation: CGPoint(
                x: x,
                y: (location.y - media.minY) / media.height
            ),
            timestamp: CACurrentMediaTime()
        )
    }

    /// Submits the current gesture position or cancels interaction when it becomes unavailable.
    private func sample() {
        guard available, let point = activePoint else { cancelInteraction(); return }
        binding?.submit(
            InteractionFrame(
                points: [point.location],
                viewportSize: bounds.size,
                contentMode: contentMode,
                displayedVideoSize: displayedSize
            ),
            from: self
        )
    }

    /// Invalidates the sampling timer.
    private func stopSampling() {
        sampler?.invalidate()
        sampler = nil
    }

    /// Fits the effect view to the viewport and installs it as a child.
    private func installRenderer() {
        renderer.view.frame = bounds
        renderer.view.autoresizingMask = [.width, .height]
        addSubview(renderer.view)
    }

    /// Cancels interaction when the application loses focus.
    @objc private func cancelFromNotification() { cancelInteraction() }

    /// Cancels interaction when this overlay's window loses keyboard focus.
    @objc private func windowResigned(
        _ notification: Notification
    ) {
        if notification.object as? NSWindow === window { cancelInteraction() }
    }
}

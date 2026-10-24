//
//  DefaultTrajectoryEffectRenderer.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit

/// The built-in glowing pointer trajectory effect.
@MainActor
public final class DefaultTrajectoryEffectRenderer: NSView,
    TrajectoryEffectRendering
{

    /// The colors, stroke widths, and fade settings for the built-in effect.
    private enum Style {

        /// The color of the bright trajectory center.
        static let coreColor = NSColor.white

        /// The color of the outer trajectory glow.
        static let glowColor = NSColor(
            srgbRed: 0,
            green: 1,
            blue: 100.0 / 255.0,
            alpha: 1
        )

        /// The center stroke width, in points.
        static let coreWidth: CGFloat = 3

        /// The outer glow width, in points.
        static let glowWidth: CGFloat = 18

        /// The fraction of accumulated trail opacity removed per refresh.
        static let fadeStep: CGFloat = 0.05

        /// The maximum number of idle fade frames before clearing the bitmap.
        static let idleFadeFrameLimit = 64
    }

    /// The current position and start time of an active gesture.
    private struct ActiveTrajectory {

        /// The latest pointer position in view coordinates.
        var location: CGPoint

        /// The monotonic gesture start time, in seconds.
        let startTime: TimeInterval
    }

    /// Whether view coordinates increase downward to match video pixels.
    public override var isFlipped: Bool { true }

    /// Whether the effect paints an opaque background.
    public override var isOpaque: Bool { false }

    /// Passes pointer input through to the SDK's interaction overlay.
    public override func hitTest(
        _ point: NSPoint
    ) -> NSView? { nil }

    /// The effect view installed above the video.
    public var view: NSView { self }

    /// The positions and start times of active pointer gestures.
    private var activeTrajectories: [TrajectoryID: ActiveTrajectory] = [:]

    /// The bitmap context accumulating fading trajectory strokes.
    private var trailBitmapContext: CGContext?

    /// The allocated trail bitmap dimensions, in pixels.
    private var trailBitmapSize: CGSize = .zero

    /// The backing scale used to allocate the trail bitmap.
    private var trailBitmapScale: CGFloat = 0

    /// Whether the bitmap contains strokes that still need fading.
    private var hasTrailPixels = false

    /// The fade frame count since the last active gesture.
    private var idleFadeFrameCount = 0

    /// The timer advancing trajectory effects on the main run loop.
    private var displayLink: Timer?

    /// Creates a programmatic trajectory effect view; archive initialization is unavailable.
    public override init(
        frame: CGRect = .zero
    ) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    /// Marks archive initialization as unavailable; create this view programmatically.
    @available(*, unavailable)
    public required init?(
        coder: NSCoder
    ) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Stops the effect refresh timer.
    isolated deinit {
        displayLink?.invalidate()
    }

    /// Updates the trail bitmap for the current view dimensions.
    public override func layout() {
        super.layout()
        rebuildTrailBitmapIfNeeded()
    }

    /// Clears effects when detached and prepares the bitmap when attached to a window.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            reset()
        } else {
            rebuildTrailBitmapIfNeeded()
        }
    }

    /// Starts visual effects for the supplied trajectories.
    ///
    /// - Parameter points: The initial pointer samples.
    public func renderBegan(
        _ points: [TrajectoryPoint]
    ) {
        for point in points {
            activeTrajectories[point.id] = ActiveTrajectory(
                location: point.location,
                startTime: point.timestamp
            )
        }
        startDisplayLink()
        needsDisplay = true
    }

    /// Updates active trajectories and draws new trail segments.
    ///
    /// - Parameter points: The latest pointer samples.
    public func renderMoved(
        _ points: [TrajectoryPoint]
    ) {
        for point in points {
            guard var trajectory = activeTrajectories[point.id] else {
                activeTrajectories[point.id] = ActiveTrajectory(
                    location: point.location,
                    startTime: point.timestamp
                )
                continue
            }

            let dx = point.location.x - trajectory.location.x
            let dy = point.location.y - trajectory.location.y
            if dx * dx + dy * dy >= 0.25 {
                drawTrailSegment(
                    from: trajectory.location,
                    to: point.location
                )
            }
            trajectory.location = point.location
            activeTrajectories[point.id] = trajectory
        }
        startDisplayLink()
    }

    /// Ends active drawing for the specified trajectories while their trails fade.
    ///
    /// - Parameter identifiers: The trajectories ending active drawing.
    public func renderEnded(
        _ identifiers: [TrajectoryID]
    ) {
        identifiers.forEach {
            activeTrajectories.removeValue(forKey: $0)
        }
        needsDisplay = true
    }

    /// Clears all trajectory effects and stops the refresh timer.
    public func reset() {
        activeTrajectories.removeAll()
        clearTrailBitmap()
        stopDisplayLink()
        needsDisplay = true
    }

    /// Draws the accumulated trail bitmap and animated pointer effects.
    ///
    /// - Parameter rect: The invalidated view region.
    public override func draw(
        _ rect: CGRect
    ) {
        if let trailImage = trailBitmapContext?.makeImage() {
            NSImage(
                cgImage: trailImage,
                size: bounds.size
            ).draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setBlendMode(.plusLighter)
        drawTouchEffects(
            now: CACurrentMediaTime(),
            in: context
        )
        context.restoreGState()
    }
}

/// The built-in glowing pointer trajectory effect.
private extension DefaultTrajectoryEffectRenderer {

    /// Advances fading and stops refreshing after all effects have disappeared.
    @objc func tick() {
        fadeTrailBitmap()
        needsDisplay = true
        if activeTrajectories.isEmpty, !hasTrailPixels {
            stopDisplayLink()
        }
    }

    /// Starts the effect refresh timer on the main run loop.
    func startDisplayLink() {
        guard displayLink == nil else { return }
        let displayLink = Timer(
            timeInterval: 1.0 / 60,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(
            displayLink,
            forMode: .common
        )
        self.displayLink = displayLink
    }

    /// Stops and releases the effect refresh timer.
    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Allocates a trail bitmap matching view dimensions and backing scale.
    func rebuildTrailBitmapIfNeeded() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = Int(ceil(bounds.width * scale))
        let pixelHeight = Int(ceil(bounds.height * scale))
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        let bitmapSize = CGSize(
            width: pixelWidth,
            height: pixelHeight
        )
        guard
            trailBitmapContext == nil
                || trailBitmapSize != bitmapSize
                || trailBitmapScale != scale
        else {
            return
        }

        let bitmapInfo =
            CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )
        else {
            return
        }

        context.translateBy(
            x: 0,
            y: CGFloat(pixelHeight)
        )
        context.scaleBy(
            x: scale,
            y: -scale
        )
        trailBitmapContext = context
        trailBitmapSize = bitmapSize
        trailBitmapScale = scale
        hasTrailPixels = false
        idleFadeFrameCount = 0
    }

    /// Adds a glowing line segment to the accumulated trail bitmap.
    ///
    /// - Parameters:
    ///   - start: The segment start in view coordinates.
    ///   - end: The segment end in view coordinates.
    func drawTrailSegment(
        from start: CGPoint,
        to end: CGPoint
    ) {
        rebuildTrailBitmapIfNeeded()
        guard let context = trailBitmapContext else { return }

        context.saveGState()
        context.setBlendMode(.plusLighter)
        drawGlowLayer(
            from: start,
            to: end,
            width: Style.glowWidth,
            blur: Style.glowWidth * 2 / 3,
            alpha: 0.22,
            in: context
        )
        drawGlowLayer(
            from: start,
            to: end,
            width: Style.glowWidth * 5 / 9,
            blur: Style.glowWidth / 3,
            alpha: 0.52,
            in: context
        )

        context.setShadow(
            offset: .zero,
            blur: 0,
            color: nil
        )
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(Style.coreWidth)
        context.setStrokeColor(
            Style.coreColor.withAlphaComponent(0.82).cgColor
        )
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()

        hasTrailPixels = true
        idleFadeFrameCount = 0
        needsDisplay = true
    }

    /// Draws one glowing stroke layer into the supplied context.
    ///
    /// - Parameters:
    ///   - start: The segment start in view coordinates.
    ///   - end: The segment end in view coordinates.
    ///   - width: The stroke width, in points.
    ///   - blur: The shadow blur radius, in points.
    ///   - alpha: The stroke opacity.
    ///   - context: The destination drawing context.
    func drawGlowLayer(
        from start: CGPoint,
        to end: CGPoint,
        width: CGFloat,
        blur: CGFloat,
        alpha: CGFloat,
        in context: CGContext
    ) {
        guard width > 0, Style.glowColor != .clear else { return }
        let color = Style.glowColor.withAlphaComponent(alpha)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(width)
        context.setStrokeColor(color.cgColor)
        if blur > 0 {
            context.setShadow(
                offset: .zero,
                blur: blur,
                color: color.cgColor
            )
        }
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    /// Reduces trail opacity and clears the bitmap after the idle fade limit.
    func fadeTrailBitmap() {
        guard hasTrailPixels, let context = trailBitmapContext else { return }
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setFillColor(
            NSColor.black.withAlphaComponent(Style.fadeStep).cgColor
        )
        context.fill(bounds)
        context.restoreGState()

        if activeTrajectories.isEmpty {
            idleFadeFrameCount += 1
            if idleFadeFrameCount > Style.idleFadeFrameLimit {
                clearTrailBitmap()
            }
        } else {
            idleFadeFrameCount = 0
        }
    }

    /// Clears accumulated strokes and resets fade state.
    func clearTrailBitmap() {
        if let context = trailBitmapContext {
            context.saveGState()
            context.setBlendMode(.clear)
            context.fill(bounds)
            context.restoreGState()
        }
        hasTrailPixels = false
        idleFadeFrameCount = 0
    }

    /// Draws rings, orbiting particles, and highlights for active trajectories.
    ///
    /// - Parameters:
    ///   - now: The current monotonic time, in seconds.
    ///   - context: The destination drawing context.
    func drawTouchEffects(
        now: TimeInterval,
        in context: CGContext
    ) {
        for trajectory in activeTrajectories.values {
            drawPulsingRings(
                for: trajectory,
                now: now,
                in: context
            )
            drawOrbitParticles(
                for: trajectory,
                now: now,
                in: context
            )
            drawHeadGlow(
                at: trajectory.location,
                in: context
            )
        }
    }

    /// Draws the pointer highlight and its radial glow.
    ///
    /// - Parameters:
    ///   - point: The pointer position in view coordinates.
    ///   - context: The destination drawing context.
    func drawHeadGlow(
        at point: CGPoint,
        in context: CGContext
    ) {
        let headRadius = max(Style.coreWidth * 5 / 3, 3)
        let glowRadius = max(Style.glowWidth * 8 / 9, headRadius)
        let colors =
            [
                Style.glowColor.withAlphaComponent(0.9).cgColor,
                Style.glowColor.withAlphaComponent(0.54).cgColor,
                Style.glowColor.withAlphaComponent(0).cgColor,
            ] as CFArray
        if Style.glowWidth > 0,
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.4, 1]
            )
        {
            context.drawRadialGradient(
                gradient,
                startCenter: point,
                startRadius: 0,
                endCenter: point,
                endRadius: glowRadius,
                options: []
            )
        }

        context.setFillColor(Style.coreColor.cgColor)
        context.fillEllipse(
            in: CGRect(
                x: point.x - headRadius,
                y: point.y - headRadius,
                width: headRadius * 2,
                height: headRadius * 2
            )
        )
    }

    /// Draws animated rings based on trajectory age.
    ///
    /// - Parameters:
    ///   - trajectory: The active trajectory to draw.
    ///   - now: The current monotonic time, in seconds.
    ///   - context: The destination drawing context.
    private func drawPulsingRings(
        for trajectory: ActiveTrajectory,
        now: TimeInterval,
        in context: CGContext
    ) {
        let elapsed = CGFloat(now - trajectory.startTime)
        context.setLineWidth(2)
        for index in 0..<2 {
            let indexValue = CGFloat(index)
            let baseRadius = 14 + indexValue * 18
            let pulseOffset = elapsed * 1.2 + indexValue * 0.5
            let pulse = (sin(pulseOffset * .pi * 2) + 1) / 2
            let radius = baseRadius + pulse * 8
            let alpha =
                0.5
                * (1 - indexValue * 0.2)
                * (0.5 + pulse * 0.5)
            context.setStrokeColor(
                Style.glowColor.withAlphaComponent(alpha).cgColor
            )
            context.strokeEllipse(
                in: CGRect(
                    x: trajectory.location.x - radius,
                    y: trajectory.location.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        }
    }

    /// Draws orbiting particles around an active trajectory.
    ///
    /// - Parameters:
    ///   - trajectory: The active trajectory to draw.
    ///   - now: The current monotonic time, in seconds.
    ///   - context: The destination drawing context.
    private func drawOrbitParticles(
        for trajectory: ActiveTrajectory,
        now: TimeInterval,
        in context: CGContext
    ) {
        let elapsed = CGFloat(now - trajectory.startTime)
        for index in 0..<4 {
            let indexValue = CGFloat(index)
            let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1
            let baseAngle = indexValue / 4 * .pi * 2
            let angle = baseAngle + elapsed * 0.06 * direction
            let center = CGPoint(
                x: trajectory.location.x + cos(angle) * 22,
                y: trajectory.location.y + sin(angle) * 22
            )
            let alpha =
                0.6
                * (0.6 + sin(elapsed * 3 + indexValue) * 0.4)
            drawParticle(
                at: center,
                alpha: alpha,
                in: context
            )
        }
    }

    /// Draws one glowing particle with a radial gradient.
    ///
    /// - Parameters:
    ///   - point: The particle center in view coordinates.
    ///   - alpha: The opacity at the particle center.
    ///   - context: The destination drawing context.
    func drawParticle(
        at point: CGPoint,
        alpha: CGFloat,
        in context: CGContext
    ) {
        let colors =
            [
                Style.glowColor.withAlphaComponent(alpha).cgColor,
                Style.glowColor.withAlphaComponent(0).cgColor,
            ] as CFArray
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            )
        else {
            return
        }
        context.drawRadialGradient(
            gradient,
            startCenter: point,
            startRadius: 0,
            endCenter: point,
            endRadius: 6,
            options: []
        )
    }
}

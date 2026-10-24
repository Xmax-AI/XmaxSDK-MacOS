//
//  RealtimeComponents.swift
//  XLab
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import CoreText
import Kingfisher
import XmaxSDK

/// Light colors matching Web X-Lab.
enum RealtimePalette {
    static let text = NSColor(srgbRed: 0.067, green: 0.075, blue: 0.094, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1)
    static let surface = NSColor(srgbRed: 0.969, green: 0.973, blue: 0.980, alpha: 1)
    static let border = NSColor(srgbRed: 0.898, green: 0.906, blue: 0.922, alpha: 1)
    static let accent = NSColor(srgbRed: 47 / 255, green: 70 / 255, blue: 226 / 255, alpha: 1)
    static let accentHover = NSColor(srgbRed: 36 / 255, green: 56 / 255, blue: 196 / 255, alpha: 1)
}

/// Uses the bundled Web font for native labels and controls.
@MainActor
enum RealtimeHeaderTypography {
    private static let registered: Void = {
        if let url = Bundle.main.url(forResource: "DMSans", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func font(size: CGFloat, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> NSFont {
        _ = registered
        guard let base = NSFont(name: "DMSans9pt-Regular", size: size) else {
            return .systemFont(ofSize: size, weight: weight)
        }
        // The bundled font has a variable weight axis; NSFont trait matching leaves it at 400.
        let value = weight == .semibold ? 600 : weight == .medium ? 500 : weight == .bold ? 700 : 400
        var attributes: [CFString: Any] = [
            kCTFontVariationAttribute: [NSNumber(value: 0x77676874): NSNumber(value: value)]
        ]
        if monospacedDigits {
            attributes[kCTFontFeatureSettingsAttribute] = [[
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector
            ]]
        }
        return CTFontCreateCopyWithAttributes(base, size, nil,
            CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)) as NSFont
    }

    static func size(_ text: String, font: NSFont, tracking: CGFloat = 0) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font, .kern: tracking])
    }
}

/// Top-left coordinates shared by the manually laid out native pages.
class RealtimeCanvas: NSView {
    override var isFlipped: Bool { true }

    init(color: NSColor = .clear, radius: CGFloat = 0) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = radius
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
func realtimeLabel(_ title: String = "", size: CGFloat = 13,
                   color: NSColor = RealtimePalette.text, weight: NSFont.Weight = .regular) -> NSTextField {
    let label = RealtimeLabel(labelWithString: title)
    label.font = RealtimeHeaderTypography.font(size: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    return label
}

/// Decorative labels let clicks reach the native control underneath them.
private final class RealtimeLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        isSelectable ? super.hitTest(point) : nil
    }
}

/// Matches xlab-react's micToggle, micSwitch and micKnob without NSSwitch's internal margins.
final class RealtimeMicrophoneToggle: NSButton {
    override var isFlipped: Bool { true }
    override var state: NSControl.StateValue { didSet { updateAppearance() } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.5 } }
    @objc dynamic private var onProgress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    private var targetProgress: CGFloat = 0

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "onProgress" { return CABasicAnimation() }
        return super.defaultAnimation(forKey: key)
    }

    init() {
        super.init(frame: .zero)
        title = "Microphone"
        font = RealtimeHeaderTypography.font(size: 13)
        // Checkbox cells only track their native indicator/title, not the custom track on the right.
        setButtonType(.pushOnPushOff)
        // Keep full-bounds mouse tracking; draw(_:) supplies the Web appearance instead of the native bezel.
        isBordered = true
        target = self
        action = #selector(didToggle)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let text = RealtimeHeaderTypography.size(title, font: font!)
        // CSS padding: 6px 7px 6px 14px; 8px gaps; 1px border.
        return NSSize(width: 2 + 14 + 14 + 8 + ceil(text.width) + 8 + 30 + 7,
                      height: 2 + 6 + max(18, ceil(text.height)) + 6)
    }

    @objc private func didToggle() {
        // Native button cells can change their state without invoking our state setter.
        updateAppearance()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func updateAppearance() {
        let progress: CGFloat = state == .on ? 1 : 0
        guard progress != targetProgress else { return }
        targetProgress = progress
        NSAnimationContext.runAnimationGroup { context in
            context.duration = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0.18 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().onProgress = progress
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityValue() -> Any? { NSNumber(value: state == .on) }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let progress = min(1, max(0, onProgress))
        let foreground = NSColor.white.withAlphaComponent(0.55 + 0.45 * progress)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(0.28).setFill()
        outline.fill()
        NSColor.white.withAlphaComponent(0.16 + 0.14 * progress).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        RealtimeWebIcon.draw(.microphone,
                            in: NSRect(x: 15, y: (bounds.height - 14) / 2, width: 14, height: 14),
                            color: foreground)
        let text = RealtimeHeaderTypography.size(title, font: font!)
        (title as NSString).draw(at: NSPoint(x: 37, y: (bounds.height - text.height) / 2),
                                 withAttributes: [.font: font!, .foregroundColor: foreground])
        let track = NSRect(x: bounds.width - 1 - 7 - 30, y: (bounds.height - 18) / 2,
                           width: 30, height: 18)
        let trackColor = NSColor(srgbRed: 1 + (47.0 / 255 - 1) * progress,
                                 green: 1 + (70.0 / 255 - 1) * progress,
                                 blue: 1 + (226.0 / 255 - 1) * progress,
                                 alpha: 0.18 + 0.82 * progress)
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: track.minX + 2 + 12 * progress,
                                   y: track.minY + 2, width: 14, height: 14)).fill()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// Draws the placeholder at the text origin and preserves input-method composition.
final class RealtimePromptTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderColor: NSColor = .placeholderTextColor
    var onCommittedTextChange: ((String) -> Void)?
    private var inputOperationDepth = 0

    var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }

    override var string: String {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsPlaceholder else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(
            at: NSPoint(x: origin.x + padding, y: origin.y),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15),
                             .foregroundColor: placeholderColor]
        )
    }

    override func didChangeText() {
        super.didChangeText()
        updateInputState()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputOperationDepth += 1
        defer { finishInputOperation() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        inputOperationDepth += 1
        defer { finishInputOperation() }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func unmarkText() {
        inputOperationDepth += 1
        defer { finishInputOperation() }
        super.unmarkText()
    }

    private func finishInputOperation() {
        inputOperationDepth -= 1
        updateInputState()
    }

    private func updateInputState() {
        needsDisplay = true
        guard inputOperationDepth == 0, !hasMarkedText() else { return }
        onCommittedTextChange?(string)
    }
}

/// Keeps the Web loading ring independent of control state updates.
final class RealtimeSpinner: RealtimeCanvas {
    private let ring = CAShapeLayer()

    init(color: NSColor = .white) {
        super.init()
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2
        ring.strokeEnd = 0.72
        ring.lineCap = .round
        layer?.addSublayer(ring)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSpinning(_ spinning: Bool, color: NSColor) {
        ring.strokeColor = color.cgColor
        isHidden = !spinning
        guard spinning, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            ring.removeAnimation(forKey: "spin")
            return
        }
        guard ring.animation(forKey: "spin") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.toValue = Double.pi * 2
        animation.duration = 0.8
        animation.repeatCount = .infinity
        ring.add(animation, forKey: "spin")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        CATransaction.commit()
    }
}

/// Native buttons retain their identity, loading animation, keyboard focus, and target action.
final class RealtimeButton: NSButton {
    enum Appearance { case pill, primary, destructive, statistics, interpolation, volume, tab, plain, dismiss }
    var style = Appearance.pill { didSet { needsDisplay = true } }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var icon: RealtimeWebIcon.Kind? { didSet { needsDisplay = true } }
    var chevron = false
    var leadingPadding: CGFloat = 14
    var trailingPadding: CGFloat = 14
    var iconSize: CGFloat = 18
    var iconSpacing: CGFloat = 8
    var tracking: CGFloat = 0
    /// Shrinks the visible background without reducing the control's hit area.
    var backgroundInset: CGFloat = 0 { didSet { needsDisplay = true } }
    var showsShadow = true { didSet { needsDisplay = true } }
    var foregroundColor: NSColor?
    var loading = false { didSet { updateLoading() } }
    var passive = false
    var onClick: (() -> Void)?
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private let spinner = RealtimeSpinner()

    override var isFlipped: Bool { true }
    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled || loading || passive ? 1 : 0.5; needsDisplay = true }
    }

    init(_ title: String = "", icon: RealtimeWebIcon.Kind? = nil,
         style: Appearance = .pill, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.title = title
        self.icon = icon
        self.style = style
        self.onClick = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        font = RealtimeHeaderTypography.font(size: 13)
        if style == .plain { leadingPadding = 0; trailingPadding = 0 }
        target = self
        self.action = #selector(invoke)
        wantsLayer = true
        addSubview(spinner)
        spinner.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { if !passive { onClick?() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    private var foreground: NSColor {
        if let foregroundColor { return foregroundColor }
        if style == .primary { return .white }
        if style == .destructive { return NSColor(srgbRed: 220 / 255, green: 38 / 255, blue: 38 / 255, alpha: 1) }
        if selected && style == .statistics { return RealtimePalette.accent }
        if selected && style == .interpolation { return NSColor(srgbRed: 169 / 255, green: 102 / 255, blue: 8 / 255, alpha: 1) }
        if style == .statistics || style == .interpolation || style == .volume {
            return selected || (hovered && isEnabled) ? RealtimePalette.text :
                NSColor(srgbRed: 139 / 255, green: 145 / 255, blue: 157 / 255, alpha: 1)
        }
        if passive || style == .plain || (style == .tab && !selected && !hovered) { return RealtimePalette.secondary }
        return RealtimePalette.text
    }

    private func updateLoading() {
        spinner.setSpinning(loading, color: foreground)
        alphaValue = isEnabled || loading || passive ? 1 : 0.5
        needsDisplay = true
        needsLayout = true
    }

    /// Mirrors SwiftUI's intrinsic label width plus the Web component's explicit padding.
    var preferredWidth: CGFloat {
        ceil(RealtimeHeaderTypography.size(title, font: font!, tracking: tracking).width +
             ((icon != nil || loading) ? iconSize + (title.isEmpty ? 0 : iconSpacing) : 0) +
             leadingPadding + trailingPadding)
    }

    private func contentFrames() -> (NSRect, NSRect) {
        let hasIcon = icon != nil || loading
        let iconWidth = hasIcon ? iconSize + (title.isEmpty ? 0 : iconSpacing) : 0
        let available = max(0, bounds.width - leadingPadding - trailingPadding - iconWidth)
        let textWidth = min(available, RealtimeHeaderTypography.size(title, font: font!, tracking: tracking).width)
        let total = iconWidth + textWidth
        let x = leadingPadding + (bounds.width - leadingPadding - trailingPadding - total) / 2
        return (NSRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize),
                NSRect(x: x + iconWidth, y: 0, width: textWidth, height: bounds.height))
    }

    override func layout() {
        super.layout()
        spinner.frame = contentFrames().0
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: backgroundInset + 0.5, dy: backgroundInset + 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let hot = hovered && isEnabled && !passive
        var top = NSColor.white
        var bottom = NSColor(srgbRed: 243 / 255, green: 244 / 255, blue: 246 / 255, alpha: 1)
        var border = hot ? NSColor(srgbRed: 201 / 255, green: 206 / 255, blue: 214 / 255, alpha: 1) :
            NSColor(srgbRed: 226 / 255, green: 229 / 255, blue: 234 / 255, alpha: 1)
        switch style {
        case .primary:
            top = hot ? RealtimePalette.accentHover : RealtimePalette.accent
            bottom = top; border = .clear
        case .dismiss:
            let gray: CGFloat = hot ? 0.32 : 0.24
            top = NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
            bottom = top; border = .clear
        case .destructive:
            bottom = NSColor(srgbRed: 253 / 255, green: hot ? 232 / 255 : 242 / 255, blue: hot ? 232 / 255 : 242 / 255, alpha: 1)
            border = foreground.withAlphaComponent(hot ? 0.5 : 0.28)
        case .statistics where selected:
            top = NSColor(srgbRed: 238 / 255, green: 241 / 255, blue: 1, alpha: 1)
            bottom = top; border = NSColor(srgbRed: 215 / 255, green: 221 / 255, blue: 251 / 255, alpha: 1)
        case .interpolation where selected:
            top = NSColor(srgbRed: 1, green: 250 / 255, blue: 240 / 255, alpha: 1)
            bottom = NSColor(srgbRed: 1, green: 240 / 255, blue: 202 / 255, alpha: 1)
            border = NSColor(srgbRed: 240 / 255, green: 207 / 255, blue: 136 / 255, alpha: 1)
        case .tab:
            top = selected ? .white : .white.withAlphaComponent(hot ? 0.65 : 0)
            bottom = top; border = .clear
        case .plain:
            top = .white.withAlphaComponent(0); bottom = top; border = .clear
        default: break
        }
        if isHighlighted { bottom = bottom.blended(withFraction: 0.06, of: .black) ?? bottom }
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)
        if style == .pill || style == .volume || style == .destructive || (!selected && (style == .statistics || style == .interpolation)) {
            let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: rect.height / 2 - 1, yRadius: rect.height / 2 - 1)
            NSColor.white.withAlphaComponent(0.6).setStroke(); highlight.lineWidth = 1; highlight.stroke()
        }
        border.setStroke(); path.lineWidth = 1; path.stroke()
        layer?.shadowColor = (style == .primary ? RealtimePalette.accent : NSColor.black).cgColor
        let flat = style == .plain || (style == .tab && !selected) || (selected && (style == .statistics || style == .interpolation))
        layer?.shadowOpacity = !showsShadow || flat ? 0 : style == .primary ? 0.35 : style == .tab ? 0.1 : hot ? 0.08 : 0.05
        layer?.shadowRadius = style == .primary ? 15 : style == .tab ? 4 : hot ? 8 : 6
        layer?.shadowOffset = CGSize(width: 0, height: style == .primary ? 10 : style == .tab ? 2 : hot ? 6 : 4)
        layer?.shadowPath = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        let (iconRect, textRect) = contentFrames()
        if let icon, !loading { RealtimeWebIcon.draw(icon, in: iconRect, color: foreground) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: foreground, .paragraphStyle: paragraph, .kern: tracking]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: textRect.minX, y: (bounds.height - height) / 2, width: textRect.width, height: height), withAttributes: attributes)
        if chevron {
            let arrow = NSBezierPath()
            let x = bounds.width - 20, y = bounds.midY
            arrow.move(to: NSPoint(x: x - 3, y: y - 1.5)); arrow.line(to: NSPoint(x: x, y: y + 1.5)); arrow.line(to: NSPoint(x: x + 3, y: y - 1.5))
            RealtimePalette.secondary.setStroke(); arrow.lineWidth = 1; arrow.stroke()
        }
    }
}

/// The same 38pt checkerboard cells as the Web landing page.
final class RealtimeCheckerboard: RealtimeCanvas {
    init() { super.init(radius: 24); layer?.masksToBounds = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // An opaque base and hard tile edges prevent seams at fractional view origins.
        context.setShouldAntialias(false)
        context.setFillColor(NSColor(srgbRed: 55 / 255, green: 55 / 255, blue: 59 / 255, alpha: 1).cgColor)
        context.fill(bounds)
        context.setFillColor(NSColor(srgbRed: 67 / 255, green: 67 / 255, blue: 71 / 255, alpha: 1).cgColor)
        for row in 0...Int(bounds.height / 38) {
            for column in 0...Int(bounds.width / 38) where (row + column).isMultiple(of: 2) {
                context.fill(CGRect(x: column * 38, y: row * 38, width: 38, height: 38))
            }
        }
    }
}

/// Displays formatted metric values without rebuilding the video or reference views.
struct RealtimeStatisticsGroup: Identifiable {
    let id: String
    var rows: [RealtimeStatisticsRow]
}

struct RealtimeStatisticsRow: Identifiable {
    let id: String
    var value = "—"
    var help = ""
    var total = false
}

final class RealtimeStatisticsPanel: RealtimeCanvas {
    private var labels: [(NSTextField, NSTextField)] = []
    private var dividers: [NSView] = []
    private var rows: [RealtimeStatisticsRow]
    let panelHeight: CGFloat
    private(set) var panelWidth: CGFloat = 0

    init(group: RealtimeStatisticsGroup) {
        rows = group.rows
        panelHeight = 16 + CGFloat(group.rows.count) * 16.5 + CGFloat(group.rows.filter(\.total).count) * 11
        super.init(color: .black.withAlphaComponent(0.6), radius: 10)
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        setAccessibilityLabel(group.id)
        for row in group.rows {
            if row.total {
                let divider = RealtimeCanvas(color: .white.withAlphaComponent(0.18))
                addSubview(divider); dividers.append(divider)
            }
            let label = realtimeLabel(row.id, size: 11, color: .white.withAlphaComponent(0.9), weight: row.total ? .semibold : .regular)
            let value = realtimeLabel(row.value, size: 11, color: .white.withAlphaComponent(0.9))
            value.font = .monospacedSystemFont(ofSize: 11, weight: row.total ? .semibold : .regular)
            value.alignment = .right
            label.toolTip = row.help; value.toolTip = row.help
            addSubview(label); addSubview(value); labels.append((label, value))
        }
        update(group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ group: RealtimeStatisticsGroup) {
        rows = group.rows
        var width: CGFloat = 0
        for (row, pair) in zip(group.rows, labels) {
            if pair.1.stringValue != row.value { pair.1.stringValue = row.value }
            let titleWidth = RealtimeHeaderTypography.size(row.id, font: pair.0.font!).width
            let valueWidth = max(64, RealtimeHeaderTypography.size(row.value, font: pair.1.font!).width)
            width = max(width, titleWidth + 16 + valueWidth + 20)
        }
        if panelWidth != ceil(width) {
            panelWidth = ceil(width)
            needsLayout = true
            superview?.needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 8
        var dividerIndex = 0
        for (row, pair) in zip(rows, labels) {
            if row.total {
                dividers[dividerIndex].frame = NSRect(x: 10, y: y + 5, width: bounds.width - 20, height: 1)
                dividerIndex += 1; y += 11
            }
            let valueWidth = max(64, ceil(RealtimeHeaderTypography.size(row.value, font: pair.1.font!).width))
            // Compensate for NSTextField's 2pt cell inset so the visible text matches the Web padding.
            pair.0.frame = NSRect(x: 8, y: y, width: bounds.width - 20 - valueWidth - 16 + 4, height: 16.5)
            pair.1.frame = NSRect(x: bounds.width - 10 - valueWidth - 2, y: y, width: valueWidth + 4, height: 16.5)
            y += 16.5
        }
    }
}

/// The SDK view remains attached throughout startup and page transitions.
final class RealtimeVideoPanel: RealtimeCanvas {
    let video = XmaxVideoView()
    private let videoContainer = RealtimeCanvas(color: .black)
    private let placeholder = realtimeLabel(size: 14, color: .white.withAlphaComponent(0.55))
    private let caption: NSTextField
    private let captionBackground = RealtimeCanvas(color: .black.withAlphaComponent(0.35), radius: 8)
    private let watermark = realtimeLabel("✦ Xmax", size: 13, color: .white.withAlphaComponent(0.8), weight: .semibold)
    private var panels: [RealtimeStatisticsPanel] = []
    var mirrored = false { didSet { if oldValue != mirrored { needsLayout = true } } }

    init(title: String, statistics: [RealtimeStatisticsGroup], showsWatermark: Bool = false) {
        caption = realtimeLabel(title, size: 12, color: .white.withAlphaComponent(0.65))
        super.init(color: .black, radius: 24)
        layer?.masksToBounds = true
        addSubview(videoContainer); videoContainer.addSubview(video)
        addSubview(placeholder); placeholder.alignment = .center
        for group in statistics {
            let panel = RealtimeStatisticsPanel(group: group)
            panels.append(panel); addSubview(panel)
        }
        addSubview(captionBackground); captionBackground.addSubview(caption); addSubview(watermark); watermark.isHidden = !showsWatermark
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(track: RealtimeVideoTrack?, message: String, statistics: [RealtimeStatisticsGroup], visible: Bool) {
        video.track = track
        if placeholder.stringValue != message { placeholder.stringValue = message }
        placeholder.isHidden = message.isEmpty
        for (panel, group) in zip(panels, statistics) { panel.isHidden = !visible; panel.update(group) }
    }

    override func layout() {
        super.layout()
        videoContainer.frame = bounds; video.frame = videoContainer.bounds
        // Mirror the SDK video layer so pointer coordinates and trajectory visuals stay aligned.
        video.isMirrored = mirrored
        placeholder.frame = NSRect(x: 20, y: bounds.midY - 10, width: bounds.width - 40, height: 20)
        let captionSize = RealtimeHeaderTypography.size(caption.stringValue, font: caption.font!)
        captionBackground.frame = NSRect(x: 14, y: bounds.height - 12 - captionSize.height - 6, width: ceil(captionSize.width) + 16, height: captionSize.height + 6)
        caption.frame = NSRect(x: 6, y: 3, width: ceil(captionSize.width) + 4, height: captionSize.height)
        let watermarkSize = RealtimeHeaderTypography.size(watermark.stringValue, font: watermark.font!)
        watermark.frame = NSRect(x: bounds.width - 16 - watermarkSize.width - 2, y: 12, width: watermarkSize.width + 4, height: watermarkSize.height)
        var y: CGFloat = 12
        for panel in panels { panel.frame = NSRect(x: 14, y: y, width: panel.panelWidth, height: panel.panelHeight); y += panel.panelHeight + 8 }
    }
}
extension RealtimeSessionController {
    var localStatisticsPanels: [RealtimeStatisticsGroup] {
        [
            .init(id: "Launch timing", rows: [
                .init(id: "Session creation", value: milliseconds(launchTiming.sessionMs),
                      help: "Time spent creating the server-side generation session"),
                .init(id: "RTC connection", value: milliseconds(launchTiming.rtcJoinMs),
                      help: "From joining the RTC channel until the connection succeeds"),
                .init(id: "Stream publication", value: milliseconds(launchTiming.publishMs),
                      help: "Time spent publishing the local media stream to the RTC channel"),
                .init(id: "First frame latency", value: milliseconds(launchTiming.firstFrameMs),
                      help: "From generation signal submission to the first display-ready result frame"),
                .init(id: "Total startup", value: milliseconds(launchTiming.totalMs),
                      help: "From SDK startup to the first display-ready result. Includes camera preparation in combined startup; overlapping stages are measured directly, not added together.", total: true)
            ]),
            .init(id: "Uplink video statistics", rows: [
                .init(id: "Uplink resolution", value: resolution(uplinkStatistics?.width, uplinkStatistics?.height)),
                .init(id: "Uplink frame rate", value: metric(uplinkStatistics?.sendFrameRate, "fps")),
                .init(id: "Uplink bitrate", value: metric(uplinkStatistics?.bitrateKbps, "kbps"))
            ]),
            .init(id: "Uplink network and latency", rows: [
                .init(id: "Uplink packet loss", value: metric(uplinkStatistics?.packetLossPercent, "%"),
                      help: "Packet loss from this SDK to the RTC cloud, not local preview loss"),
                .init(id: "Uplink network quality", value: quality(networkQuality?.uplink)),
                .init(id: "Uplink RTT", help: "Not exposed by the macOS SDK")
            ])
        ]
    }

    var remoteStatisticsPanels: [RealtimeStatisticsGroup] {
        [
            .init(id: "Downlink video statistics", rows: [
                .init(id: "Downlink resolution", value: resolution(downlinkStatistics?.width, downlinkStatistics?.height)),
                .init(id: "Downlink frame rate", value: metric(downlinkStatistics?.renderFrameRate, "fps")),
                .init(id: "Downlink bitrate", value: metric(downlinkStatistics?.bitrateKbps, "kbps"))
            ]),
            .init(id: "Downlink network and latency", rows: [
                .init(id: "Playback buffer delay", help: "Not exposed by the macOS SDK"),
                .init(id: "Downlink packet loss", value: metric(downlinkStatistics?.packetLossPercent, "%")),
                .init(id: "Downlink network quality", value: quality(networkQuality?.downlink)),
                .init(id: "RTT (cloud)", help: "Not exposed by the macOS SDK"),
                .init(id: "E2E (RTC estimate)", value: metric(downlinkStatistics?.endToEndDelayMs, "ms"))
            ])
        ]
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.1f ms", $0) } ?? "—"
    }
    private func metric(_ value: Int?, _ unit: String) -> String { value.map { "\($0) \(unit)" } ?? "—" }
    private func resolution(_ width: Int?, _ height: Int?) -> String {
        guard let width, let height else { return "—" }
        return "\(width) × \(height)"
    }
    private func quality(_ level: RealtimeNetworkQualityLevel?) -> String {
        guard let level else { return "—" }
        return level == .veryBad ? "Very bad" : level.rawValue
    }
}

/// Draws the existing Web icon coordinates directly into the AppKit graphics context.
@MainActor
enum RealtimeWebIcon {
    enum Kind { case camera, microphone, statistics, muted, volume, volumeLow, lightning, plus, close, arrow, globe, socialX, wechat, key, stop }

    static func draw(_ kind: Kind, in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 24, y: rect.height / 24)
        context.addPath(path(kind))
        context.setFillColor(color.cgColor); context.setStrokeColor(color.cgColor)
        context.setLineWidth(kind == .arrow || kind == .close ? 3 : kind == .plus || kind == .microphone ? 2 : 1.8)
        context.setLineCap(.round); context.setLineJoin(.round)
        if kind == .lightning || kind == .socialX || kind == .wechat || kind == .stop { context.drawPath(using: .eoFill) }
        else { context.strokePath() }
        context.restoreGState()
    }

    private static func path(_ kind: Kind) -> CGPath {
        var p = CGMutablePath()
        func line(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            p.move(to: first)
            for point in points.dropFirst() { p.addLine(to: point) }
        }
        func points(_ values: [(CGFloat, CGFloat)]) -> [CGPoint] { values.map { CGPoint(x: $0.0, y: $0.1) } }
        switch kind {
        case .stop:
            p.addRect(CGRect(x: 5, y: 5, width: 14, height: 14))
        case .key:
            p.addEllipse(in: CGRect(x: 2, y: 10, width: 11, height: 11))
            line(points([(11.39,11.61),(21,2)]))
            line(points([(15.5,7.5),(18.5,10.5),(22,7),(19,4)]))
        case .camera:
            p.addRoundedRect(in: CGRect(x: 2, y: 6, width: 14, height: 12), cornerWidth: 3, cornerHeight: 3)
            line(points([(16,10),(22,6.5),(22,17.5),(16,14)]))
        case .microphone:
            p.addRoundedRect(in: CGRect(x: 9, y: 2, width: 6, height: 13), cornerWidth: 3, cornerHeight: 3)
            p.move(to: CGPoint(x: 19,y: 10)); p.addLine(to: CGPoint(x: 19,y: 12))
            p.addCurve(to: CGPoint(x: 5,y: 12), control1: CGPoint(x: 19,y: 21.3), control2: CGPoint(x: 5,y: 21.3))
            p.addLine(to: CGPoint(x: 5,y: 10)); line(points([(12,19),(12,22)]))
        case .statistics:
            line(points([(4,4),(4,20),(20,20)])); line(points([(8,15),(8,11)]))
            line(points([(13,15),(13,7)])); line(points([(18,15),(18,9)]))
        case .muted, .volume, .volumeLow:
            line(points([(11,4),(6,8),(3,8),(3,16),(6,16),(11,20),(11,4)]))
            if kind == .muted {
                line(points([(16,9),(22,15)])); line(points([(22,9),(16,15)]))
            } else {
                p.move(to: CGPoint(x: 15,y: 8))
                p.addCurve(to: CGPoint(x: 15,y: 16), control1: CGPoint(x: 18,y: 10), control2: CGPoint(x: 18,y: 14))
                if kind == .volume {
                    p.move(to: CGPoint(x: 18,y: 5))
                    p.addCurve(to: CGPoint(x: 18,y: 19), control1: CGPoint(x: 24,y: 9), control2: CGPoint(x: 24,y: 15))
                }
            }
        case .lightning:
            line(points([(13.7,2.3),(4.2,13),(10.4,14.2),(9.5,21.7),(19.8,11),(12.9,9.8),(13.7,2.3)])); p.closeSubpath()
        case .plus: line(points([(12,4),(12,20)])); line(points([(4,12),(20,12)]))
        case .close: line(points([(5,5),(19,19)])); line(points([(19,5),(5,19)]))
        case .arrow: line(points([(4,12),(20,12)])); line(points([(14,6),(20,12),(14,18)]))
        case .globe:
            p.addEllipse(in: CGRect(x: 2,y: 2,width: 20,height: 20)); line(points([(2,12),(22,12)]))
            p.move(to: CGPoint(x: 12,y: 2))
            p.addCurve(to: CGPoint(x: 12,y: 22), control1: CGPoint(x: 17.3,y: 7), control2: CGPoint(x: 17.3,y: 17))
            p.addCurve(to: CGPoint(x: 12,y: 2), control1: CGPoint(x: 6.7,y: 17), control2: CGPoint(x: 6.7,y: 7))
        case .socialX:
            line(points([(18.244,2.25),(21.552,2.25),(14.325,10.51),(22.827,21.75),(16.17,21.75),(10.956,14.933),(4.99,21.75),(1.68,21.75),(9.41,12.915),(1.254,2.25),(8.08,2.25),(12.793,8.481),(18.244,2.25)])); p.closeSubpath()
            line(points([(17.083,19.77),(18.916,19.77),(6.95,4.126),(5.117,4.126),(17.083,19.77)])); p.closeSubpath()
        case .wechat:
            p.move(to: CGPoint(x: 9.3, y: 4))
            p.addCurve(to: CGPoint(x: 2.6, y: 9.9), control1: CGPoint(x: 5.6, y: 4), control2: CGPoint(x: 2.6, y: 6.6))
            p.addCurve(to: CGPoint(x: 5.2, y: 14.5), control1: CGPoint(x: 2.6, y: 11.8), control2: CGPoint(x: 3.6, y: 13.4))
            p.addLine(to: CGPoint(x: 4.5, y: 16.7)); p.addLine(to: CGPoint(x: 6.9, y: 15.5))
            p.addCurve(to: CGPoint(x: 9.3, y: 15.8), control1: CGPoint(x: 7.6, y: 15.7), control2: CGPoint(x: 8.4, y: 15.8))
            p.addLine(to: CGPoint(x: 9.8, y: 15.8))
            p.addCurve(to: CGPoint(x: 9.6, y: 14.5), control1: CGPoint(x: 9.7, y: 15.4), control2: CGPoint(x: 9.6, y: 14.9))
            p.addCurve(to: CGPoint(x: 16, y: 8.9), control1: CGPoint(x: 9.6, y: 11.4), control2: CGPoint(x: 12.5, y: 8.9))
            p.addLine(to: CGPoint(x: 16.3, y: 8.9))
            p.addCurve(to: CGPoint(x: 9.3, y: 4), control1: CGPoint(x: 15.7, y: 6.2), control2: CGPoint(x: 12.8, y: 4))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: 6.4, y: 7.2, width: 1.8, height: 1.8))
            p.addEllipse(in: CGRect(x: 10.8, y: 7.2, width: 1.8, height: 1.8))
            p.move(to: CGPoint(x: 15.8, y: 9.9))
            p.addCurve(to: CGPoint(x: 10.2, y: 14.5), control1: CGPoint(x: 12.7, y: 9.9), control2: CGPoint(x: 10.2, y: 11.9))
            p.addCurve(to: CGPoint(x: 15.8, y: 19.1), control1: CGPoint(x: 10.2, y: 17), control2: CGPoint(x: 12.7, y: 19.1))
            p.addCurve(to: CGPoint(x: 17.7, y: 18.8), control1: CGPoint(x: 16.4, y: 19.1), control2: CGPoint(x: 17.1, y: 19))
            p.addLine(to: CGPoint(x: 19.7, y: 19.8)); p.addLine(to: CGPoint(x: 19.2, y: 18))
            p.addCurve(to: CGPoint(x: 21.4, y: 14.5), control1: CGPoint(x: 20.5, y: 17.2), control2: CGPoint(x: 21.4, y: 15.9))
            p.addCurve(to: CGPoint(x: 15.8, y: 9.9), control1: CGPoint(x: 21.4, y: 12), control2: CGPoint(x: 18.9, y: 9.9))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: 13.4, y: 12.4, width: 1.6, height: 1.6))
            p.addEllipse(in: CGRect(x: 16.6, y: 12.4, width: 1.6, height: 1.6))
            var transform = CGAffineTransform(a: 1.15, b: 0, c: 0, d: 1.15, tx: -1.8, ty: -1.8)
            p = p.mutableCopy(using: &transform) ?? p
        }
        return p
    }
}

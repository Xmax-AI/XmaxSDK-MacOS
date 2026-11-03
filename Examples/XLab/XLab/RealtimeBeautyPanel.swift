//
//  RealtimeBeautyPanel.swift
//  XLab
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import XmaxSDK

/// Edits generated-result strengths over the same translucent surface as the statistics panels.
@MainActor
final class RealtimeBeautyPanel: RealtimeCanvas {
    var onChange: ((RealtimeVideoBeautyOptions) -> Void)?
    private var options = RealtimeVideoBeautyOptions()
    private let rows: [(WritableKeyPath<RealtimeVideoBeautyOptions, Float>, RealtimeBeautySliderRow)]
    private var visible = false
    private var dismissal: Task<Void, Never>?
    let preferredSize: NSSize

    init() {
        let settings: [(String, WritableKeyPath<RealtimeVideoBeautyOptions, Float>)] = [
            ("Smoothness", \.smoothness), ("Lightening", \.lightening),
            ("Sharpness", \.sharpness), ("Redness", \.redness)
        ]
        let labelWidth = ceil(settings.map {
            ($0.0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        }.max() ?? 0)
        preferredSize = NSSize(width: labelWidth + 148, height: 110)
        rows = settings.map { ($0.1, RealtimeBeautySliderRow(title: $0.0, labelWidth: labelWidth)) }
        super.init(color: .black.withAlphaComponent(0.6), radius: 8)
        appearance = NSAppearance(named: .darkAqua)
        isHidden = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        setAccessibilityLabel("Result beauty")
        for (key, row) in rows {
            addSubview(row)
            row.onChange = { [weak self] value in
                guard let self, self.visible else { return }
                self.options[keyPath: key] = value
                self.onChange?(self.options)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(options: RealtimeVideoBeautyOptions, enabled: Bool, visible: Bool) {
        self.options = options
        for (key, row) in rows { row.update(value: options[keyPath: key], enabled: enabled && visible) }
        guard self.visible != visible else { return }
        self.visible = visible
        dismissal?.cancel()
        dismissal = nil
        let animated = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible {
            alphaValue = animated ? 0 : 1
            isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.3 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = visible ? 1 : 0
        }
        if !visible {
            if !animated { isHidden = true; return }
            dismissal = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self, !self.visible else { return }
                self.isHidden = true
                self.dismissal = nil
            }
        }
    }

    override func layout() {
        super.layout()
        for (index, entry) in rows.enumerated() {
            entry.1.frame = NSRect(x: 8, y: 8 + CGFloat(index) * 24, width: bounds.width - 16, height: 22)
        }
    }
}

/// Keeps the four native slider tracks and their percentage labels aligned.
@MainActor
private final class RealtimeBeautySliderRow: RealtimeCanvas {
    var onChange: ((Float) -> Void)?
    private let titleLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "0%")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let labelWidth: CGFloat

    init(title: String, labelWidth: CGFloat) {
        titleLabel = NSTextField(labelWithString: title)
        self.labelWidth = labelWidth
        super.init()
        for label in [titleLabel, valueLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .white.withAlphaComponent(0.9)
            addSubview(label)
        }
        valueLabel.alignment = .right
        slider.controlSize = .mini
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel(title)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: Float, enabled: Bool) {
        let percent = Int((value * 100).rounded())
        slider.doubleValue = Double(percent)
        valueLabel.stringValue = "\(percent)%"
        slider.isEnabled = enabled
        alphaValue = enabled ? 1 : 0.45
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 0, y: 4, width: labelWidth, height: 16)
        valueLabel.frame = NSRect(x: bounds.width - 30, y: 4, width: 30, height: 16)
        slider.frame = NSRect(x: labelWidth + 6, y: 0, width: bounds.width - labelWidth - 48, height: 22)
    }

    @objc private func sliderChanged() {
        let percent = Int(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(percent)%"
        onChange?(Float(percent) / 100)
    }
}

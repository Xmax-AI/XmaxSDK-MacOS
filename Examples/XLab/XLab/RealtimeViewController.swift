//
//  RealtimeViewController.swift
//  XLab
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import Combine
import Kingfisher
import UniformTypeIdentifiers
import XmaxSDK

/// Owns persistent AppKit pages and applies coalesced session state updates to individual controls.
@MainActor
final class RealtimeViewController: NSViewController, NSTextFieldDelegate {
    let controller = RealtimeSessionController()

    /// Window content and page containers
    private let root = RealtimeCanvas(color: .white)
    private let scroll = NSScrollView()
    private let document = RealtimeCanvas()
    private let header = RealtimeCanvas()
    private let landing = RealtimeCanvas()
    private let workspace = RealtimeCanvas()
    private let footer = RealtimeCanvas()
    private let logo = NSImageView()
    private let homeControls = RealtimeCanvas()
    private let sessionControls = RealtimeCanvas()
    private let titleLabel = realtimeLabel("Reimagining Live Video with Xmax", size: 32, weight: .medium)
    private let checkerboard = RealtimeCheckerboard()
    private let startButton = RealtimeButton("Start Camera", icon: .camera, style: .primary)
    private let microphoneToggle = RealtimeMicrophoneToggle()
    private let terms = NSTextView()
    private let copyright = realtimeLabel("Copyright © 2026 XMAX.AI PTE.LTD. All rights reserved.", size: 13, color: RealtimePalette.secondary)
    private let wechat = RealtimeButton(icon: .wechat, style: .plain)
    private let social = RealtimeButton(icon: .socialX, style: .plain)
    private let website = RealtimeButton(icon: .globe, style: .plain)
    private let contact = RealtimeButton("Contact Us", style: .plain)
    private let platform = RealtimeButton("API Platform", style: .plain)

    /// Header settings and session actions
    private let modelButton = RealtimeButton()
    private let keyButton = RealtimeButton(icon: .key)
    private let currentModel = RealtimeButton()
    private let statisticsButton = RealtimeButton(icon: .statistics, style: .statistics)
    private let volumeButton = RealtimeButton(icon: .muted, style: .volume)
    private let interpolationButton = RealtimeButton("2x", icon: .lightning, style: .interpolation)
    private let elapsed = RealtimeButton("00:00")
    private let recordButton = RealtimeButton("Record", icon: .record, style: .recording)
    private let stopButton = RealtimeButton("Stop Session", icon: .stop, style: .destructive)
    private let keyField = NSTextField()
    private let volumeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeValue = realtimeLabel("Muted", size: 12, color: RealtimePalette.secondary)
    private var popover: NSPopover?
    private var volumeTask: Task<Void, Never>?
    private var pendingVolume: Float?

    /// Persistent video panels and mode-specific editors
    private lazy var localPanel = RealtimeVideoPanel(title: "Local", statistics: controller.localStatisticsPanels)
    private lazy var resultPanel = RealtimeVideoPanel(title: "Result", statistics: controller.remoteStatisticsPanels, showsWatermark: true)
    private let tabs = RealtimeCanvas(color: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.1), radius: 21)
    private var tabButtons: [RealtimeExampleMode: RealtimeButton] = [:]
    private var lists: [RealtimeExampleMode: RealtimeReferenceList] = [:]
    private let promptContainer = RealtimeCanvas(color: RealtimePalette.surface, radius: 18)
    private let promptScroll = NSScrollView()
    private let promptEditor = RealtimePromptTextView()
    private let freeReference = RealtimeReferenceButton()
    private let removeReference = RealtimeButton(icon: .close, style: .dismiss)
    private let submitButton = RealtimeButton(icon: .arrow, style: .primary)

    /// Error presentation and observation ownership
    private let toast = RealtimeCanvas(color: .white.withAlphaComponent(0.96), radius: 14)
    private let toastIcon = NSImageView()
    private let toastMessage = realtimeLabel(size: 14)
    private let toastDismiss = RealtimeButton("×", style: .plain)
    private var observation: AnyCancellable?
    private var renderScheduled = false
    private var displayedSession: Bool?
    private var displayedMode: RealtimeExampleMode?
    private var displayedError: String?
    private var errorTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var recordingSaveTask: Task<Void, Never>?

    override func loadView() {
        view = root
        root.frame = NSRect(x: 0, y: 0, width: 1360, height: 850)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        root.addSubview(scroll)
        [header, landing, workspace, footer].forEach(document.addSubview)
        configureHeader()
        configureLanding()
        configureWorkspace()
        configureFooter()
        configureToast()
        observation = controller.objectWillChange.sink { [weak self] in
            // Published values notify before assignment; one main-queue turn reads the committed state.
            self?.scheduleRender()
        }
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    if let self, self.controller.sessionActive {
                        await self.controller.refreshInterpolationState()
                        self.updateElapsed()
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    func shutdown() async {
        observation = nil
        await controller.stopRecording()
        scheduleRecordingSave()
        await recordingSaveTask?.value
        ticker?.cancel(); ticker = nil
        errorTask?.cancel(); errorTask = nil
        pendingVolume = nil
        volumeTask?.cancel(); volumeTask = nil
        popover?.close()
        for list in lists.values { list.suspendImages() }
        await controller.shutdown()
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.render()
        }
    }

    private func configureHeader() {
        logo.image = NSImage(named: "XmaxWordmark")
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("Xmax")
        [logo, homeControls, sessionControls].forEach(header.addSubview)
        [modelButton, keyButton].forEach(homeControls.addSubview)
        [currentModel, statisticsButton, volumeButton, interpolationButton, elapsed, recordButton, stopButton].forEach(sessionControls.addSubview)
        modelButton.font = RealtimeHeaderTypography.font(size: 12)
        modelButton.leadingPadding = 18; modelButton.trailingPadding = 30
        modelButton.chevron = true
        keyButton.font = RealtimeHeaderTypography.font(size: 12)
        keyButton.iconSize = 14
        currentModel.font = RealtimeHeaderTypography.font(size: 13, weight: .medium)
        elapsed.font = RealtimeHeaderTypography.font(size: 13, weight: .medium, monospacedDigits: true)
        for button in [statisticsButton, volumeButton, interpolationButton, recordButton, stopButton] {
            button.font = RealtimeHeaderTypography.font(size: 13, weight: .semibold)
        }
        interpolationButton.iconSize = 15; interpolationButton.iconSpacing = 3
        interpolationButton.leadingPadding = 12; interpolationButton.trailingPadding = 15
        stopButton.iconSize = 12; stopButton.iconSpacing = 7
        stopButton.leadingPadding = 16; stopButton.trailingPadding = 16
        recordButton.iconSize = 12; recordButton.iconSpacing = 7
        recordButton.onClick = { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                if self.controller.isRecording { await self.controller.stopRecording() }
                else { await self.controller.startRecording() }
            }
        }
        modelButton.onClick = { [weak self] in self?.showModels() }
        keyButton.toolTip = "API Key"; keyButton.setAccessibilityLabel("API Key")
        keyButton.onClick = { [weak self] in self?.showKeyEditor() }
        currentModel.passive = true; currentModel.isEnabled = false
        elapsed.passive = true; elapsed.isEnabled = false
        statisticsButton.setAccessibilityLabel("Show statistics")
        statisticsButton.onClick = { [weak self] in self?.controller.statisticsVisible.toggle() }
        volumeButton.toolTip = "Adjust remote playback volume"
        volumeButton.setAccessibilityLabel("Remote volume")
        volumeButton.onClick = { [weak self] in self?.showVolume() }
        interpolationButton.setAccessibilityLabel("Frame interpolation")
        interpolationButton.onClick = { [weak self] in
            Task { [weak self] in await self?.controller.toggleInterpolation() }
        }
        stopButton.onClick = { [weak self] in Task { [weak self] in await self?.controller.close() } }
        keyField.delegate = self
        keyField.placeholderString = "API Key"
        keyField.font = RealtimeHeaderTypography.font(size: 13)
        keyField.bezelStyle = .roundedBezel
        keyField.setAccessibilityLabel("API Key")
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged)
        volumeSlider.isContinuous = true
        volumeSlider.setAccessibilityLabel("Remote volume")
    }

    private func configureLanding() {
        [titleLabel, checkerboard, copyright].forEach(landing.addSubview)
        titleLabel.alignment = .center; copyright.alignment = .center
        [startButton, microphoneToggle, terms].forEach(checkerboard.addSubview)
        startButton.onClick = { [weak self] in
            guard let self else { return }
            let enabled = self.microphoneToggle.state == .on
            Task { [weak self] in await self?.controller.start(useMicrophone: enabled) }
        }
        terms.isEditable = false; terms.isSelectable = true; terms.drawsBackground = false
        terms.textContainerInset = .zero
        terms.textContainer?.lineFragmentPadding = 0
        terms.linkTextAttributes = [.foregroundColor: NSColor(srgbRed: 0.765, green: 0.776, blue: 0.8, alpha: 1)]
    }

    private func configureWorkspace() {
        [localPanel, resultPanel, tabs, promptContainer].forEach(workspace.addSubview)
        for mode in RealtimeExampleMode.allCases {
            let button = RealtimeButton(mode.title, style: .tab)
            button.font = RealtimeHeaderTypography.font(size: 13.5, weight: .medium)
            button.tracking = 0.135
            button.leadingPadding = 22; button.trailingPadding = 22
            button.onClick = { [weak self] in self?.controller.activeMode = mode }
            tabs.addSubview(button); tabButtons[mode] = button
            if mode != .free {
                let list = RealtimeReferenceList()
                list.onUpload = { [weak self] in self?.presentImporter(mode: mode) }
                list.onSelect = { [weak self] reference in
                    Task { [weak self] in await self?.controller.selectReference(reference) }
                }
                workspace.addSubview(list); lists[mode] = list
            }
        }
        promptContainer.layer?.borderWidth = 1
        promptContainer.layer?.borderColor = RealtimePalette.border.cgColor
        promptEditor.placeholder = "Describe how you want the video to change"
        promptEditor.placeholderColor = RealtimePalette.secondary
        promptEditor.onCommittedTextChange = { [weak self] text in
            guard let self, self.controller.prompt != text else { return }
            self.controller.prompt = text
        }
        promptEditor.font = RealtimeHeaderTypography.font(size: 15)
        promptEditor.textColor = RealtimePalette.text
        promptEditor.isRichText = false; promptEditor.drawsBackground = false
        promptEditor.isVerticallyResizable = true; promptEditor.isHorizontallyResizable = false
        promptEditor.autoresizingMask = [.width]
        promptEditor.textContainerInset = .zero
        promptEditor.textContainer?.lineFragmentPadding = 0
        promptEditor.textContainer?.widthTracksTextView = true
        promptEditor.setAccessibilityLabel("Describe how you want the video to change")
        promptScroll.drawsBackground = false; promptScroll.hasVerticalScroller = true
        promptScroll.documentView = promptEditor
        [promptScroll, freeReference, removeReference, submitButton].forEach(promptContainer.addSubview)
        freeReference.compact = true
        freeReference.onClick = { [weak self] in
            guard let self else { return }
            if let reference = self.controller.freeReference, reference.uploadState == .error {
                Task { [weak self] in await self?.controller.selectReference(reference) }
            } else if self.controller.freeReference == nil { self.presentImporter(mode: .free) }
        }
        removeReference.toolTip = "Remove reference"
        removeReference.setAccessibilityLabel("Remove reference")
        removeReference.iconSize = 11
        removeReference.foregroundColor = .white
        removeReference.backgroundInset = 6
        removeReference.leadingPadding = 0
        removeReference.trailingPadding = 0
        // Keep a 32pt hit area around the smaller 20pt circular background.
        removeReference.isBordered = true
        removeReference.onClick = { [weak self] in self?.controller.removeFreeReference() }
        submitButton.iconSize = 20
        submitButton.showsShadow = false
        submitButton.setAccessibilityLabel("Submit prompt")
        submitButton.onClick = { [weak self] in Task { [weak self] in await self?.controller.submitPrompt() } }
    }

    private func configureFooter() {
        [wechat, social, website, contact, platform].forEach(footer.addSubview)
        wechat.iconSize = 20; social.iconSize = 18; website.iconSize = 20
        wechat.setAccessibilityLabel("WeChat"); social.setAccessibilityLabel("X"); website.setAccessibilityLabel("Website")
        wechat.onClick = { [weak self] in self?.showWeChat() }
        social.onClick = { NSWorkspace.shared.open(URL(string: "https://x.com/XmaxAIOfficial")!) }
        website.onClick = { NSWorkspace.shared.open(URL(string: "https://www.xmaxai.com")!) }
        contact.onClick = { NSWorkspace.shared.open(URL(string: "mailto:contact@xmax.ai")!) }
        platform.onClick = { NSWorkspace.shared.open(URL(string: "https://platform.xmaxai.com")!) }
    }

    private func configureToast() {
        root.addSubview(toast)
        [toastIcon, toastMessage, toastDismiss].forEach(toast.addSubview)
        toast.layer?.borderWidth = 1; toast.layer?.borderColor = RealtimePalette.text.withAlphaComponent(0.08).cgColor
        toast.layer?.shadowColor = NSColor.black.cgColor; toast.layer?.shadowOpacity = 0.14
        toast.layer?.shadowRadius = 16; toast.layer?.shadowOffset = CGSize(width: 0, height: 8)
        toastIcon.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
        toastIcon.contentTintColor = .systemRed
        toastIcon.imageScaling = .scaleProportionallyUpOrDown
        toastMessage.maximumNumberOfLines = 0; toastMessage.lineBreakMode = .byWordWrapping
        toastMessage.cell?.usesSingleLineMode = false
        toastMessage.cell?.wraps = true
        toastMessage.cell?.isScrollable = false
        toastMessage.isSelectable = true
        toastDismiss.setAccessibilityLabel("Dismiss")
        toastDismiss.onClick = { [weak self] in self?.controller.dismissError() }
    }

    /// Updates values without replacing controls, resetting list offsets, or restarting image requests.
    private func render() {
        let active = controller.sessionActive
        let pageChanged = displayedSession != active
        let keyTitle = controller.hasAPIKey ? controller.apiKey : ""
        let recordTitle = controller.isFinishingRecording ? "Finishing…" :
            controller.recordingToSave != nil ? "Saving…" : controller.isRecording ? "Stop Recording" : "Record"
        let needsPageLayout = pageChanged || keyButton.title != keyTitle ||
            modelButton.title != controller.model.displayName || displayedError != controller.errorMessage ||
            recordButton.title != recordTitle
        modelButton.title = controller.model.displayName
        modelButton.isEnabled = !controller.isBusy
        currentModel.title = controller.model.displayName
        keyButton.title = keyTitle
        startButton.title = controller.isClosing ? "Stopping…" : controller.isBusy ? "Starting…" : "Start Camera"
        startButton.loading = controller.isBusy
        startButton.isEnabled = !controller.isBusy
        microphoneToggle.isEnabled = !controller.isBusy
        statisticsButton.selected = controller.statisticsVisible
        statisticsButton.toolTip = controller.statisticsVisible ? "Hide statistics (collection and logging continue)" : "Show statistics"
        statisticsButton.setAccessibilityValue(controller.statisticsVisible ? "On" : "Off")
        volumeButton.icon = controller.remoteAudioVolume == 0 ? .muted : controller.remoteAudioVolume > 0.5 ? .volume : .volumeLow
        volumeButton.selected = controller.remoteAudioVolume > 0
        volumeButton.isEnabled = !controller.isClosing
        volumeButton.setAccessibilityValue(controller.remoteAudioVolume == 0 ? "Muted" : "\(Int(controller.remoteAudioVolume * 100))%")
        volumeSlider.isEnabled = !controller.isClosing
        if volumeTask == nil { volumeSlider.doubleValue = Double(controller.remoteAudioVolume) }
        volumeValue.stringValue = controller.remoteAudioVolume == 0 ? "Muted" : "\(Int(controller.remoteAudioVolume * 100))%"
        interpolationButton.selected = controller.interpolationEnabled
        interpolationButton.loading = controller.interpolationSwitching
        interpolationButton.isEnabled = !controller.isBusy
        interpolationButton.toolTip = controller.interpolationSwitching ? "Switching frame interpolation…" : controller.interpolationEnabled ? "2× frame interpolation is on. Click to turn off" : "Frame interpolation is off. Click to turn on"
        interpolationButton.setAccessibilityValue(controller.interpolationSwitching ? "Switching" : controller.interpolationEnabled ? "On" : "Off")
        stopButton.title = controller.isClosing ? "Stopping…" : "Stop Session"
        stopButton.loading = controller.isClosing
        stopButton.isEnabled = !controller.isClosing
        recordButton.title = recordTitle
        recordButton.selected = controller.isRecording
        recordButton.loading = controller.isFinishingRecording
        recordButton.isEnabled = controller.isRecording || controller.canRecord
        recordButton.toolTip = controller.isRecording ? "Stop recording and save the remote result" : "Record remote video and audio"
        recordButton.setAccessibilityLabel(recordTitle)
        scheduleRecordingSave()
        updateElapsed()

        // The preview is bound even while the landing page is visible, as required by SDK readiness.
        localPanel.update(track: controller.localStream?.videoTrack, message: "", statistics: controller.localStatisticsPanels, visible: controller.statisticsVisible)
        let placeholder = controller.state.connectionState == .generating && controller.remoteStream != nil ? "" :
            [.connected, .generating].contains(controller.state.connectionState) ? "Generating…" : "Waiting for connection…"
        resultPanel.update(track: controller.remoteStream?.videoTrack, message: placeholder, statistics: controller.remoteStatisticsPanels, visible: controller.statisticsVisible)
        for (mode, button) in tabButtons {
            button.selected = controller.activeMode == mode
            button.isEnabled = !controller.isBusy
            button.setAccessibilityValue(button.selected ? "Selected" : "")
        }
        for (mode, list) in lists {
            let visible = active && controller.activeMode == mode
            if !visible && !list.isHidden { list.suspendImages() }
            list.isHidden = !visible
            if visible {
                list.update(references: controller.uploadedReferences.filter { $0.mode == mode } + mode.presets,
                            selectedID: controller.selectedReferenceID, enabled: controller.canGenerate,
                            dimmed: !controller.canGenerate && !controller.interpolationSwitching)
            }
        }
        promptContainer.isHidden = controller.activeMode != .free
        promptEditor.isEditable = !controller.isClosing
        if !promptEditor.hasMarkedText(), promptEditor.string != controller.prompt {
            promptEditor.string = controller.prompt
        }
        if active && controller.activeMode == .free {
            freeReference.configure(controller.freeReference, selected: false, enabled: controller.canGenerate)
        } else { freeReference.thumbnail.cancel() }
        removeReference.isHidden = controller.freeReference == nil
        removeReference.isEnabled = !controller.isBusy
        submitButton.isEnabled = controller.canGenerate && !controller.referenceUploading
        if displayedMode != controller.activeMode {
            // Resign the editor when switching modes so hidden text cannot receive keyboard input.
            if displayedMode == .free { view.window?.makeFirstResponder(nil) }
            displayedMode = controller.activeMode
        }
        homeControls.isHidden = active; sessionControls.isHidden = !active
        landing.isHidden = active; footer.isHidden = active
        workspace.isHidden = !active
        if pageChanged {
            displayedSession = active
            popover?.close()
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            view.window?.makeFirstResponder(nil)
        }
        updateError()
        if needsPageLayout { view.needsLayout = true }
        if pageChanged {
            view.layoutSubtreeIfNeeded()
            animateEntry(active ? workspace : landing)
            if !active { animateEntry(footer) }
        }
    }

    private func updateElapsed() {
        let seconds = max(0, Int(Date().timeIntervalSince(controller.sessionStartedAt ?? Date())))
        let title = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        if elapsed.title != title {
            let previousWidth = elapsed.preferredWidth
            elapsed.title = title
            if previousWidth != elapsed.preferredWidth { view.needsLayout = true }
        }
    }

    private func animateEntry(_ page: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.45
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 14; move.toValue = 0; move.duration = 0.45; move.timingFunction = fade.timingFunction
        page.layer?.add(fade, forKey: "pageEntryOpacity")
        page.layer?.add(move, forKey: "pageEntryPosition")
    }

    private func updateError() {
        toast.isHidden = controller.errorMessage == nil
        guard displayedError != controller.errorMessage else { return }
        displayedError = controller.errorMessage
        toastMessage.stringValue = controller.errorMessage ?? ""
        errorTask?.cancel()
        guard let message = controller.errorMessage else { return }
        NSAccessibility.post(element: toastMessage, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.controller.dismissError()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        scroll.frame = root.bounds
        let width = scroll.contentSize.width
        let height = scroll.contentSize.height
        let contentWidth = max(0, width - 56)
        let panelWidth = (contentWidth - 24) / 2
        let panelHeight = panelWidth * 1024 / 1920
        let workspaceHeight = panelHeight + 34 + 42 + 28 + 190
        let stageWidth = min(contentWidth, min(940, max(580, width * 0.45)))
        let stageHeight = stageWidth * 1024 / 1920
        let titleSize = min(45, max(27, width * 0.01 + 18))
        let titleGap = min(40, max(26, width * 0.011 + 17))
        let titleFont = RealtimeHeaderTypography.font(size: titleSize, weight: .medium)
        let titleHeight = ceil(RealtimeHeaderTypography.size(titleLabel.stringValue, font: titleFont).height)
        copyright.font = RealtimeHeaderTypography.font(size: min(14, max(11.5, width * 0.0028 + 9)))
        let copyrightHeight = ceil(RealtimeHeaderTypography.size(copyright.stringValue, font: copyright.font!).height)
        let landingHeight = titleHeight + titleGap + stageHeight + 16 + copyrightHeight
        let logoHeight = min(52, max(34, width * 0.008 + 24))
        let controlHeight = controller.sessionActive ? 36 : min(48, max(35, width * 0.0055 + 26))
        let headerHeight = max(logoHeight, controlHeight) + 8 + 24
        let footerHeight: CGFloat = 56 + 24
        let active = controller.sessionActive
        let minimumHeight = active ? 16 + headerHeight + workspaceHeight + 48 : 16 + headerHeight + 30 + landingHeight + 30 + footerHeight + 48
        let documentHeight = max(height, minimumHeight)
        document.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        let surplus = max(0, documentHeight - minimumHeight)
        header.frame = NSRect(x: 28, y: 16 + (active ? surplus / 2 : 0), width: contentWidth, height: headerHeight)
        layoutHeader(viewportWidth: width)
        landing.frame = NSRect(x: 28, y: header.frame.maxY + 30 + surplus / 2, width: contentWidth, height: landingHeight)
        titleLabel.attributedStringValue = NSAttributedString(string: "Reimagining Live Video with Xmax", attributes: [
            .font: RealtimeHeaderTypography.font(size: titleSize, weight: .medium),
            .foregroundColor: RealtimePalette.text, .kern: -titleSize * 0.03,
            .paragraphStyle: { let style = NSMutableParagraphStyle(); style.alignment = .center; return style }()
        ])
        titleLabel.frame = NSRect(x: 0, y: 0, width: contentWidth, height: titleHeight)
        checkerboard.frame = NSRect(x: (contentWidth - stageWidth) / 2, y: titleHeight + titleGap, width: stageWidth, height: stageHeight)
        layoutLanding(viewportWidth: width)
        copyright.frame = NSRect(x: 0, y: checkerboard.frame.maxY + 16, width: contentWidth, height: copyrightHeight)
        workspace.frame = NSRect(x: 28, y: header.frame.maxY, width: contentWidth, height: workspaceHeight)
        localPanel.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        resultPanel.frame = NSRect(x: panelWidth + 24, y: 0, width: panelWidth, height: panelHeight)
        let tabWidths = RealtimeExampleMode.allCases.map { tabButtons[$0]!.preferredWidth }
        let tabWidth = tabWidths.reduce(0, +) + 2 * CGFloat(tabWidths.count - 1) + 8
        tabs.frame = NSRect(x: (contentWidth - tabWidth) / 2, y: panelHeight + 34, width: tabWidth, height: 42)
        var x: CGFloat = 4
        for (mode, itemWidth) in zip(RealtimeExampleMode.allCases, tabWidths) {
            tabButtons[mode]?.frame = NSRect(x: x, y: 4, width: itemWidth, height: 34)
            x += itemWidth + 2
        }
        let listY = tabs.frame.maxY + 28
        for list in lists.values { list.frame = NSRect(x: 0, y: listY, width: contentWidth, height: 190) }
        let promptWidth = min(contentWidth, 880)
        promptContainer.frame = NSRect(x: (contentWidth - promptWidth) / 2, y: listY + 4, width: promptWidth, height: 160)
        let promptPadding: CGFloat = 18
        let promptHeight: CGFloat = 96 - promptPadding
        promptScroll.frame = NSRect(x: promptPadding, y: promptPadding,
                                    width: promptWidth - 2 * promptPadding, height: promptHeight)
        promptEditor.setFrameSize(NSSize(width: promptScroll.contentSize.width,
                                         height: max(promptHeight, promptEditor.frame.height)))
        freeReference.frame = NSRect(x: promptWidth - 110, y: 104, width: 44, height: 44)
        removeReference.frame = NSRect(x: promptWidth - 88, y: 92, width: 32, height: 32)
        submitButton.frame = NSRect(x: promptWidth - 56, y: 104, width: 44, height: 44)
        footer.frame = NSRect(x: 28, y: documentHeight - 48 - footerHeight, width: contentWidth, height: footerHeight)
        wechat.frame = NSRect(x: 0, y: 56, width: 24, height: 24)
        social.frame = NSRect(x: 42, y: 56, width: 24, height: 24)
        website.frame = NSRect(x: 84, y: 56, width: 24, height: 24)
        contact.frame = NSRect(x: contentWidth - 210, y: 56, width: 98, height: 26)
        platform.frame = NSRect(x: contentWidth - 100, y: 56, width: 100, height: 26)
        layoutToast()
    }

    private func layoutHeader(viewportWidth width: CGFloat) {
        let logoHeight = min(52, max(34, width * 0.008 + 24))
        let controlHeight = min(48, max(35, width * 0.0055 + 26))
        let rowHeight = header.bounds.height - 8 - 24
        logo.frame = NSRect(x: 0, y: 8 + (rowHeight - logoHeight) / 2, width: logoHeight * 552 / 172, height: logoHeight)
        let keyWidth = controller.hasAPIKey ? min(270 + 14 + 8 + 28, keyButton.preferredWidth) : controlHeight
        let modelWidth = modelButton.preferredWidth
        let homeWidth = modelWidth + 12 + keyWidth
        homeControls.frame = NSRect(x: header.bounds.width - homeWidth, y: 8 + (rowHeight - controlHeight) / 2, width: homeWidth, height: controlHeight)
        modelButton.frame = NSRect(x: 0, y: 0, width: modelWidth, height: controlHeight)
        keyButton.frame = NSRect(x: modelWidth + 12, y: 0, width: keyWidth, height: controlHeight)
        let stopWidth = ceil(RealtimeHeaderTypography.size("Stop Session", font: stopButton.font!).width) + 12 + 7 + 32
        let controls: [(RealtimeButton, CGFloat)] = [
            (currentModel, currentModel.preferredWidth), (statisticsButton, 36), (volumeButton, 36),
            (interpolationButton, interpolationButton.preferredWidth), (elapsed, elapsed.preferredWidth),
            (recordButton, recordButton.preferredWidth), (stopButton, stopWidth)
        ]
        let sessionWidth = controls.reduce(CGFloat(0)) { $0 + $1.1 } + CGFloat(controls.count - 1) * 12
        sessionControls.frame = NSRect(x: header.bounds.width - sessionWidth, y: 8 + (rowHeight - 36) / 2, width: sessionWidth, height: 36)
        var x: CGFloat = 0
        for (button, size) in controls {
            button.frame = NSRect(x: x, y: 0, width: size, height: 36)
            x += size + 12
        }
    }

    private func layoutLanding(viewportWidth width: CGFloat) {
        let fontSize = min(18, max(15, width * 0.003 + 12))
        let smallSize = min(15, max(12, width * 0.0028 + 9.5))
        startButton.font = RealtimeHeaderTypography.font(size: fontSize, weight: .semibold)
        startButton.iconSize = 20; startButton.iconSpacing = 10
        startButton.leadingPadding = min(40, max(25, width * 0.0075 + 18))
        startButton.trailingPadding = startButton.leadingPadding
        let buttonHeight = max(20, ceil(RealtimeHeaderTypography.size(startButton.title, font: startButton.font!).height)) + min(16, max(12, width * 0.0028 + 9)) * 2
        let buttonWidth = startButton.preferredWidth
        microphoneToggle.font = RealtimeHeaderTypography.font(size: smallSize)
        let microphoneSize = microphoneToggle.intrinsicContentSize
        let actionGap: CGFloat = 20
        let groupHeight = buttonHeight + actionGap + microphoneSize.height
        startButton.frame = NSRect(x: (checkerboard.bounds.width - buttonWidth) / 2, y: (checkerboard.bounds.height - groupHeight) / 2, width: buttonWidth, height: buttonHeight)
        microphoneToggle.frame = NSRect(x: (checkerboard.bounds.width - microphoneSize.width) / 2,
                                        y: startButton.frame.maxY + actionGap,
                                        width: microphoneSize.width, height: microphoneSize.height)
        let text = "By clicking Start, you agree to our Terms of Use and Privacy Policy."
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: RealtimeHeaderTypography.font(size: smallSize), .paragraphStyle: paragraph,
            .foregroundColor: NSColor(srgbRed: 0.612, green: 0.639, blue: 0.686, alpha: 1)
        ])
        attributed.addAttribute(.link, value: "https://platform.xmaxai.com/docs/resources/terms", range: (text as NSString).range(of: "Terms of Use"))
        attributed.addAttribute(.link, value: "https://platform.xmaxai.com/docs/resources/privacy", range: (text as NSString).range(of: "Privacy Policy"))
        let termsWidth = checkerboard.bounds.width - 40
        let termsHeight = ceil(attributed.boundingRect(with: NSSize(width: termsWidth, height: 100), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        terms.frame = NSRect(x: 20, y: checkerboard.bounds.height - 30 - termsHeight, width: termsWidth, height: termsHeight)
        if !terms.attributedString().isEqual(to: attributed) { terms.textStorage?.setAttributedString(attributed) }
    }

    private func layoutToast() {
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 12
        let iconSize: CGFloat = 20
        let gap: CGFloat = 10
        let dismissSize: CGFloat = 24
        let accessoryWidth = horizontalPadding * 2 + iconSize + dismissSize + gap * 2
        let maximumWidth = min(560, max(0, root.bounds.width - 56))
        // Include NSTextField's cell insets, then wrap only when the maximum width is reached.
        let naturalTextWidth = ceil(toastMessage.attributedStringValue.size().width) + 4
        let width = min(maximumWidth, naturalTextWidth + accessoryWidth)
        let textWidth = max(1, width - accessoryWidth)
        let textHeight = ceil(toastMessage.cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude
        )).height ?? 0)
        let height = max(textHeight, iconSize, dismissSize) + verticalPadding * 2
        toast.frame = NSRect(x: (root.bounds.width - width) / 2, y: 84, width: width, height: height)
        toastIcon.frame = NSRect(x: horizontalPadding, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        toastMessage.frame = NSRect(x: horizontalPadding + iconSize + gap, y: (height - textHeight) / 2,
                                    width: textWidth, height: textHeight)
        toastDismiss.frame = NSRect(x: width - horizontalPadding - dismissSize, y: (height - dismissSize) / 2,
                                    width: dismissSize, height: dismissSize)
    }

    /// Popovers use native fields and controls, keeping keyboard editing independent of session redraws.
    private func presentPopover(content: NSView, from button: NSView) {
        popover?.close()
        let controller = NSViewController(); controller.view = content
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = controller; popover.contentSize = content.frame.size
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func showModels() {
        let content = RealtimeCanvas(); content.frame.size = NSSize(width: 256, height: CGFloat(RealtimeModel.allCases.count) * 36 + 16)
        for (index, model) in RealtimeModel.allCases.enumerated() {
            let option = RealtimeButton(model.displayName + (controller.model == model ? "  ✓" : ""), style: .tab)
            option.selected = controller.model == model
            option.frame = NSRect(x: 8, y: CGFloat(index) * 36 + 8, width: 240, height: 34)
            option.onClick = { [weak self] in
                guard let self, !self.controller.isBusy else { return }
                self.controller.model = model; self.popover?.close()
            }
            content.addSubview(option)
        }
        presentPopover(content: content, from: modelButton)
    }

    private func showKeyEditor() {
        let content = RealtimeCanvas(); content.frame.size = NSSize(width: 280, height: 56)
        keyField.stringValue = controller.apiKey
        keyField.frame = NSRect(x: 10, y: 10, width: 260, height: 36)
        content.addSubview(keyField)
        presentPopover(content: content, from: keyButton)
        keyField.window?.makeFirstResponder(keyField)
    }

    private func showVolume() {
        let content = RealtimeCanvas(); content.frame.size = NSSize(width: 244, height: 88)
        let label = realtimeLabel("Remote volume", size: 12)
        label.frame = NSRect(x: 14, y: 14, width: 145, height: 18)
        volumeValue.frame = NSRect(x: 159, y: 14, width: 71, height: 18); volumeValue.alignment = .right
        volumeSlider.frame = NSRect(x: 14, y: 46, width: 216, height: 24)
        [label, volumeValue, volumeSlider].forEach(content.addSubview)
        presentPopover(content: content, from: volumeButton)
    }

    @objc private func volumeChanged() {
        let value = Float(volumeSlider.doubleValue)
        volumeValue.stringValue = value == 0 ? "Muted" : "\(Int(value * 100))%"
        pendingVolume = value
        guard volumeTask == nil else { return }
        volumeTask = Task { [weak self] in
            guard let self else { return }
            while let value = self.pendingVolume, !Task.isCancelled {
                self.pendingVolume = nil
                await self.controller.setRemoteAudioVolume(value)
            }
            self.volumeTask = nil
            self.scheduleRender()
        }
    }

    private func showWeChat() {
        let content = RealtimeCanvas(); content.frame.size = NSSize(width: 208, height: 242)
        let image = NSImageView(frame: NSRect(x: 14, y: 14, width: 180, height: 180))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.kf.setImage(with: URL(string: "https://assets.22duck.fun/image/wechatAccount.jpg"), options: [
            .processor(DownsamplingImageProcessor(size: NSSize(width: 180, height: 180))),
            .scaleFactor(view.window?.backingScaleFactor ?? 2), .backgroundDecode
        ])
        let label = realtimeLabel("Follow us on WeChat", size: 12)
        label.alignment = .center; label.frame = NSRect(x: 14, y: 202, width: 180, height: 24)
        content.addSubview(image); content.addSubview(label)
        presentPopover(content: content, from: wechat)
    }

    /// Presents each completed clip once, including when disconnecting or terminating the app.
    private func scheduleRecordingSave() {
        guard recordingSaveTask == nil, let url = controller.recordingToSave else { return }
        recordingSaveTask = Task { @MainActor in
            await presentRecordingSave(url)
            controller.releaseRecording(url)
            recordingSaveTask = nil
        }
    }

    private func presentRecordingSave(_ source: URL) async {
        while true {
            let panel = NSSavePanel()
            panel.title = "Save Recording"
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.canCreateDirectories = true
            let date = DateFormatter()
            date.dateFormat = "yyyy-MM-dd-HHmmss"
            panel.nameFieldStringValue = "XLab-\(date.string(from: Date())).mp4"
            let response = await withCheckedContinuation { continuation in
                if let window = view.window, window.isVisible {
                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                } else { panel.begin { continuation.resume(returning: $0) } }
            }
            guard response == .OK, let destination = panel.url else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try RealtimeMediaRecorder.save(source, to: destination)
                }.value
                return
            } catch {
                let alert = NSAlert()
                alert.messageText = "Unable to Save Recording"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Discard Recording")
                let choice: NSApplication.ModalResponse
                if let window = view.window, window.isVisible {
                    choice = await alert.beginSheetModal(for: window)
                } else { choice = alert.runModal() }
                if choice != .alertFirstButtonReturn { return }
            }
        }
    }

    private func presentImporter(mode: RealtimeExampleMode) {
        guard controller.canGenerate, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in await self?.controller.uploadReference(at: url, mode: mode) }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === keyField { controller.apiKey = keyField.stringValue }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            popover?.close(); return true
        }
        return false
    }
}

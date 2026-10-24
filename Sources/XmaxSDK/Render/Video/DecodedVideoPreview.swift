//
//  DecodedVideoPreview.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Delivers decoded frames to the bound SDK video view.
@MainActor
final class DecodedVideoPreviewPresenter {

    /// The local preview video view.
    private weak var view: XmaxVideoView?

    /// The local video content mode.
    private var contentMode = VideoContentMode.fill

    /// Whether local preview is horizontally mirrored.
    private var mirrored = false

    /// Binds the video view and applies preview scaling and mirroring.
    ///
    /// - Parameters:
    ///   - view: The SDK video view receiving decoded frames.
    ///   - contentMode: The video scaling and cropping mode.
    func attach(
        to view: XmaxVideoView,
        contentMode: VideoContentMode
    ) {
        self.view = view
        self.contentMode = contentMode
        view.prepareDecodedVideoPreview(contentMode: contentMode)
        view.setDecodedVideoPreviewMirrored(mirrored)
    }

    /// Clears decoded preview from the specified view and removes the binding.
    ///
    /// - Parameter view: The view whose preview should be removed.
    func detach(
        from view: XmaxVideoView
    ) {
        view.clearDecodedVideoPreview()
        if self.view === view {
            self.view = nil
        }
    }

    /// Submits decoded frames to the bound view.
    ///
    /// - Parameter frame: The neutral video frame to display.
    func display(
        _ frame: VideoFrame
    ) {
        view?.displayDecodedVideoFrame(
            frame,
            contentMode: contentMode
        )
    }

    /// Updates preview mirroring and applies it to the current view.
    ///
    /// - Parameter mirrored: Whether to mirror video horizontally.
    func setMirrored(
        _ mirrored: Bool
    ) {
        self.mirrored = mirrored
        view?.setDecodedVideoPreviewMirrored(mirrored)
    }

    /// Clears preview content and releases the view binding.
    func clear() {
        view?.clearDecodedVideoPreview()
        view = nil
    }
}

/// Coalesces preview frames that the main thread cannot display in time, retaining only the latest.
final class DecodedVideoPreviewDispatcher: @unchecked Sendable {

    /// The video preview presenter.
    private let presenter: DecodedVideoPreviewPresenter

    /// The lock protecting pending frames and main-actor delivery.
    private let lock = NSLock()

    /// The latest frame awaiting main-actor delivery.
    private var pendingFrame: VideoFrame?

    /// Whether a main-actor delivery is pending.
    private var isDeliveryScheduled = false

    /// Creates a dispatcher coalescing preview frames onto the main thread.
    init(
        presenter: DecodedVideoPreviewPresenter
    ) {
        self.presenter = presenter
    }

    /// Updates the pending frame and schedules main-thread delivery when needed.
    ///
    /// - Parameter frame: The latest displayable video frame.
    func enqueue(
        _ frame: VideoFrame
    ) {
        let shouldSchedule = lock.withLock { () -> Bool in
            pendingFrame = frame
            guard !isDeliveryScheduled else { return false }
            isDeliveryScheduled = true
            return true
        }
        if shouldSchedule {
            scheduleDelivery()
        }
    }

    /// Discards preview frames not yet submitted.
    func reset() {
        lock.withLock {
            pendingFrame = nil
        }
    }

    /// Schedules a main-thread preview delivery.
    private func scheduleDelivery() {
        Task { @MainActor [weak self] in
            self?.deliverLatestFrame()
        }
    }

    /// Displays the latest pending frame and schedules further delivery when needed.
    @MainActor
    private func deliverLatestFrame() {
        let frame = lock.withLock { () -> VideoFrame? in
            let frame = pendingFrame
            pendingFrame = nil
            return frame
        }
        if let frame {
            presenter.display(frame)
        }

        let shouldScheduleAgain = lock.withLock { () -> Bool in
            if pendingFrame == nil {
                isDeliveryScheduled = false
                return false
            }
            return true
        }
        if shouldScheduleAgain {
            scheduleDelivery()
        }
    }
}

//
//  RtcCameraPreviewPresenter.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit

/// Binds an SDK view to Agora's native renderer without reading or copying local video pixels.
@MainActor
final class RtcCameraPreviewPresenter {

    /// The RTC manager owning native camera rendering.
    private let rtcManager: any RtcManaging

    /// The SDK video view hosting native rendering.
    private weak var view: XmaxRealtimeVideoView?

    /// The native renderer's child canvas.
    private weak var canvasView: NSView?

    /// The requested proportional fitting or cropping mode.
    private var contentMode: VideoContentMode = .fill

    /// Whether the camera source requires mirrored presentation.
    private var sourceMirrored: Bool

    /// Creates a native camera preview presenter.
    init(
        rtcManager: any RtcManaging,
        mirrored: Bool
    ) {
        self.rtcManager = rtcManager
        sourceMirrored = mirrored
    }

    /// Creates a native canvas and binds preview updates to the SDK view.
    func attach(
        to view: XmaxRealtimeVideoView,
        contentMode: VideoContentMode
    ) throws {
        self.view = view
        self.contentMode = contentMode
        canvasView = view.prepareNativeVideoPreview()
        view.nativePreviewUpdateHandler = { [weak self] in
            do { try self?.update() } catch {
                XmaxRealtimeVideoView.logRenderingFailure(
                    title: "Failed to update native camera preview",
                    error: error
                )
            }
        }
        try update()
    }

    /// Updates source mirroring and reapplies native preview configuration.
    func setMirrored(
        _ mirrored: Bool
    ) throws {
        sourceMirrored = mirrored
        try update()
    }

    /// Clears the preview when the specified SDK view is the current host.
    func detach(
        from view: XmaxRealtimeVideoView
    ) throws {
        guard self.view === view else { return }
        try clear()
    }

    /// Detaches native rendering and clears canvas references even if detachment fails.
    func clear() throws {
        defer {
            view?.clearNativeVideoPreview()
            view = nil
            canvasView = nil
        }
        if let canvasView { try rtcManager.detachCameraPreview(from: canvasView) }
    }

    /// Applies content mode and effective mirroring to the current native canvas.
    private func update() throws {
        guard let view, let canvasView else { return }
        try rtcManager.attachCameraPreview(
            to: canvasView,
            contentMode: contentMode,
            mirrored: sourceMirrored || view.isMirrored
        )
    }
}

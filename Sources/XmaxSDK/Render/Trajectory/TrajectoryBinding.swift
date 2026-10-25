//
//  TrajectoryBinding.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit

/// Connects one remote viewport to media interaction without owning task or transport state.
@MainActor
final class TrajectoryBinding {

    /// The receiver submitting viewport trajectories to the media layer.
    private let listener: RenderInteractionListener

    /// The immutable resolved media dimensions used for trajectory mapping.
    private let resolvedMediaSize: CGSize

    /// The viewport currently attached to this binding.
    private weak var overlay: TrajectoryOverlayView?

    /// Whether the track binding still accepts interaction.
    private var valid = true

    /// Whether the active generation task permits interaction.
    private var enabled = false

    /// The revision rejecting queued input from an earlier gesture or task.
    private var revision = 0

    /// Creates a viewport binding with an interaction receiver.
    init(
        listener: @escaping RenderInteractionListener,
        resolvedMediaSize: CGSize
    ) {
        self.listener = listener
        self.resolvedMediaSize = resolvedMediaSize
    }

    /// Attaches a viewport and invalidates input from its previous attachment.
    func attach(
        to overlay: TrajectoryOverlayView
    ) {
        guard valid else { return }
        if self.overlay !== overlay {
            revision += 1
            self.overlay?.setBinding(
                nil,
                enabled: false
            )
            self.overlay = overlay
        }
        overlay.setResolvedMediaSize(resolvedMediaSize)
        overlay.setBinding(
            self,
            enabled: enabled
        )
    }

    /// Detaches the matching viewport and cancels queued input from it.
    func detach(
        from overlay: TrajectoryOverlayView
    ) {
        guard self.overlay === overlay else { return }
        revision += 1
        self.overlay = nil
        overlay.setBinding(
            nil,
            enabled: false
        )
        overlay.setResolvedMediaSize(nil)
    }

    /// A task or stream boundary cancels the old gesture even if interaction remains enabled.
    func update(
        enabled: Bool
    ) {
        revision += 1
        self.enabled = enabled
        overlay?.setBinding(
            self,
            enabled: valid && enabled
        )
    }

    /// Forwards input only while the viewport, generation, and binding revision remain current.
    func submit(
        _ frame: InteractionFrame,
        from overlay: TrajectoryOverlayView
    ) {
        guard valid, enabled, self.overlay === overlay else { return }
        let revision = revision
        Task { [weak self, weak overlay] in
            guard let self, let overlay, self.valid, self.enabled,
                self.revision == revision, self.overlay === overlay
            else { return }
            await self.listener(frame)
        }
    }

    /// Permanently rejects input and removes the viewport binding.
    func invalidate() {
        valid = false
        update(enabled: false)
        overlay?.setBinding(
            nil,
            enabled: false
        )
        overlay?.setResolvedMediaSize(nil)
        overlay = nil
    }
}

//
//  VideoRenderBinding.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit

/// Binds a realtime video track to an AppKit render view.
@MainActor
final class VideoRenderBinding {

    /// The operation attaching this track to a video view.
    private let attachHandler: (NSView, VideoContentMode) throws -> Void

    /// The operation removing this track from a video view.
    private let detachHandler: (NSView) throws -> Void

    /// The current rendering host without ownership of its lifetime.
    private weak var attachedView: NSView?

    /// Creates a track-to-view render binding.
    init(
        attachHandler: @escaping (NSView, VideoContentMode) throws -> Void,
        detachHandler: @escaping (NSView) throws -> Void
    ) {
        self.attachHandler = attachHandler
        self.detachHandler = detachHandler
    }

    /// Unbinds the old view before binding content to the target view.
    ///
    /// - Parameters:
    ///   - view: The new render target view.
    ///   - contentMode: The video scaling and cropping mode.
    ///
    /// - Throws: An error if unbinding the old view or binding the new view fails.
    func attach(
        to view: NSView,
        contentMode: VideoContentMode
    ) throws {
        if let attachedView, attachedView !== view {
            try detachHandler(attachedView)
            self.attachedView = nil
        }

        try attachHandler(
            view,
            contentMode
        )
        attachedView = view
    }

    /// Unbinds rendering only if the specified view is currently bound.
    ///
    /// - Parameter view: The view to unbind.
    ///
    /// - Throws: An error if the underlying unbind operation fails.
    func detach(
        from view: NSView
    ) throws {
        guard attachedView === view else {
            return
        }
        try detach()
    }

    /// Clears image preview and removes the current view render binding.
    ///
    /// - Throws: An error if the underlying unbind operation fails.
    func detach() throws {
        guard let attachedView else {
            return
        }
        try detachHandler(attachedView)
        self.attachedView = nil
    }
}

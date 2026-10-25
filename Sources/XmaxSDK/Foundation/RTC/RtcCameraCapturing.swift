//
//  RtcCameraCapturing.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import AppKit

/// Native camera capture and local preview are owned by the RTC engine.
struct RtcCameraConfiguration: Sendable, Equatable {

    /// The system camera device identifier.
    let deviceID: String

    /// The requested capture width, in pixels.
    let width: Int

    /// The requested capture height, in pixels.
    let height: Int

    /// The requested capture frame rate, in frames per second.
    let frameRate: Int
}

/// Native camera capture and AppKit preview controls for an RTC engine.
protocol RtcCameraCapturing: Sendable {

    /// Starts native capture and reports readiness or failure through the supplied callbacks.
    func startCameraCapture(
        configuration: RtcCameraConfiguration,
        previewReadyListener: @escaping @Sendable () -> Void,
        errorListener: @escaping XmaxErrorListener
    ) throws

    /// Switches the active native capture device.
    func switchCameraCapture(
        to deviceID: String
    ) throws

    /// Updates native capture dimensions and frame rate while retaining the device and preview binding.
    func updateCameraCapture(
        videoFormat: VideoFormat,
        frameRate: Int
    ) throws

    /// Stops native camera capture and preview.
    func stopCameraCapture() throws

    /// Attaches the active camera renderer to an AppKit view on the main actor.
    @MainActor func attachCameraPreview(
        to view: NSView,
        contentMode: VideoContentMode,
        mirrored: Bool
    ) throws

    /// Detaches the matching AppKit view without stopping capture.
    @MainActor func detachCameraPreview(
        from view: NSView
    ) throws
}

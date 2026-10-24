//
//  CameraCaptureManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Manages system cameras and raw video frame output.
protocol CameraCaptureManaging: Sendable {

    /// Whether capture supplies RTC video directly instead of using the raw frame listener.
    var suppliesRTCVideo: Bool { get }

    /// Sets the callback for native capture readiness; decoded capture uses frame delivery instead.
    func setNativePreviewReadyListener(
        _ listener: (@Sendable () -> Void)?
    )

    /// Lists currently available camera devices.
    ///
    /// - Returns: Devices with their identifiers, names, and default status.
    func listCameraDevices() -> [CameraDevice]

    /// Starts the specified device using the configured dimensions and frame rate.
    ///
    /// - Parameters:
    ///   - videoFormat: The output pixel format and dimensions.
    ///   - frameRate: The target capture frame rate.
    ///   - deviceID: The capture device identifier.
    ///   - frameListener: Receives decoded frames on the capture queue when `suppliesRTCVideo` is false.
    ///   - errorListener: Receives capture runtime errors.
    ///
    /// - Throws: An error on invalid devices or formats, or capture startup failure.
    func start(
        videoFormat: VideoFormat,
        frameRate: Int,
        deviceID: String,
        frameListener: @escaping @Sendable (VideoFrame) throws -> Void,
        errorListener: @escaping XmaxErrorListener
    ) async throws

    /// Switches cameras while retaining output dimensions and frame rate.
    ///
    /// - Parameter deviceID: The target device identifier.
    ///
    /// - Throws: An error if the device is unavailable or switching fails.
    func switchCamera(
        to deviceID: String
    ) async throws

    /// Stops capture and clears capture callbacks.
    func stop() async
}

extension CameraCaptureManaging {

    /// Whether capture supplies RTC video directly instead of using the raw frame listener.
    var suppliesRTCVideo: Bool { false }

    /// Sets the callback for native capture readiness; decoded capture uses frame delivery instead.
    func setNativePreviewReadyListener(
        _ listener: (@Sendable () -> Void)?
    ) {}
}

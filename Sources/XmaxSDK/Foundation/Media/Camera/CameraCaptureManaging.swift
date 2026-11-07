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

/// Manages native RTC camera capture.
protocol CameraCaptureManaging: Sendable {

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
    ///   - previewReadyListener: Reports when native capture is ready.
    ///   - errorListener: Receives capture runtime errors.
    ///
    /// - Throws: An error on invalid devices or formats, or capture startup failure.
    func start(
        videoFormat: VideoFormat,
        frameRate: Int,
        deviceID: String,
        previewReadyListener: @escaping @Sendable () -> Void,
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

    /// Updates output dimensions and frame rate while retaining the camera device and callbacks.
    func updateFormat(
        _ videoFormat: VideoFormat,
        frameRate: Int
    ) async throws

    /// Stops capture and clears capture callbacks.
    func stop() async
}

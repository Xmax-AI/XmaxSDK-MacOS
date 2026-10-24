//
//  CameraCaptureManaging.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Manages system cameras and raw video frame output.
protocol CameraCaptureManaging: Sendable {

    /// True when RTC captures and publishes directly; observed frames must not be pushed back to RTC.
    var suppliesRTCVideo: Bool { get }

    /// Native rendering reports readiness without sending raw pixels through the SDK.
    func setNativePreviewReadyListener(_ listener: (@Sendable () -> Void)?)

    /// Lists currently available camera devices.
    ///
    /// - Returns: Devices with their identifiers, names, and default status.
    func listCameraDevices() -> [CameraDevice]

    /// Starts the specified device and outputs NV12 frames at the target dimensions.
    ///
    /// - Parameters:
    ///   - videoFormat: The output pixel format and dimensions.
    ///   - frameRate: The target capture frame rate.
    ///   - deviceID: The capture device identifier.
    ///   - frameListener: Receives video frames on the serial capture queue.
    ///   - errorListener: Receives capture runtime errors.
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
    /// - Throws: An error if the device is unavailable or switching fails.
    func switchCamera(to deviceID: String) async throws

    /// Stops capture, waits for in-flight frames, and releases the device.
    func stop() async
}

extension CameraCaptureManaging {
    var suppliesRTCVideo: Bool { false }
    func setNativePreviewReadyListener(_ listener: (@Sendable () -> Void)?) {}
}

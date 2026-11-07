//
//  CameraDeviceDiscovery.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AVFoundation

/// Lists cameras without starting capture.
enum CameraDeviceDiscovery {

    /// Lists camera devices without creating a capture session.
    static func availableCameraDevices() -> [CameraDevice] {
        let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID
        return Self.captureDevices().map { device in
            CameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID,
                position: Self.resolvePosition(
                    device.position,
                    deviceType: device.deviceType
                )
            )
        }
    }

    /// Converts system camera positions to SDK positions; treats built-in macOS cameras with unknown positions as
    /// front-facing.
    ///
    /// - Parameters:
    ///   - position: The camera position reported by the system.
    ///   - deviceType: The device type used to identify built-in cameras.
    ///
    /// - Returns: The camera position used for preview mirroring.
    static func resolvePosition(
        _ position: AVCaptureDevice.Position,
        deviceType: AVCaptureDevice.DeviceType
    ) -> CameraPosition {
        if position == .front { return .front }
        if position == .back { return .back }
        return deviceType == .builtInWideAngleCamera ? .front : .unspecified
    }

    /// Lists system video devices without starting capture.
    ///
    /// - Returns: The system's current video capture devices.
    static func captureDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}

//
//  MediaDevices.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Queries local media devices independently of credentials, capture, and realtime connections.
public enum MediaDevices {

    /// Lists camera devices without starting capture or requesting camera permission.
    ///
    /// - Returns: The current camera devices, including their identifiers and default status.
    public static func listCameraDevices() async -> [CameraDevice] {
        await Task.detached {
            CameraCaptureManager.availableCameraDevices()
        }.value
    }

    /// Lists audio inputs without starting capture or requesting microphone permission.
    ///
    /// Physical and virtual inputs are included. Your app can filter its own virtual outputs.
    /// Each call reads a fresh snapshot; unavailable device descriptions are omitted.
    ///
    /// - Returns: Inputs sorted by name, with stable UIDs and system default status.
    ///   Returns an empty array if the system device list cannot be read.
    public static func listMicrophoneDevices() async -> [MicrophoneDevice] {
        await Task.detached {
            MicrophoneDeviceDiscovery.list()
        }.value
    }
}

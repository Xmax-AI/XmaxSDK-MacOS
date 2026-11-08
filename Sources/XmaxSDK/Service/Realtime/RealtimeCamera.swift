//
//  RealtimeCamera.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The camera input used to create a local camera stream.
public enum RealtimeCamera: Equatable, Sendable {

    /// Uses the system default camera when the stream is created.
    case systemDefault

    /// Uses the camera identifier returned by `listCameraDevices()`.
    case device(id: String)

    /// The explicit camera identifier, or nil when using the system default.
    var deviceID: String? {
        guard case let .device(id) = self else { return nil }
        return id
    }

    /// Converts the legacy optional camera identifier into a camera selection.
    init(deviceID: String?) {
        if let deviceID {
            self = .device(id: deviceID)
        } else {
            self = .systemDefault
        }
    }
}

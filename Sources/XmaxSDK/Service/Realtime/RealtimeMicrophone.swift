//
//  RealtimeMicrophone.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The microphone input captured and published when a local camera stream connects.
public enum RealtimeMicrophone: Equatable, Sendable {

    /// Leaves microphone permission, capture, and publication disabled.
    case disabled

    /// Captures the system default input, following subsequent system input changes.
    case systemDefault

    /// Captures the input identified by a stable Core Audio device UID.
    /// Use an identifier returned by `listMicrophoneDevices()`.
    case device(id: String)

    /// Whether the selection requests microphone permission and capture while connected.
    var isEnabled: Bool {
        self != .disabled
    }

    /// The explicit input UID, or nil when the selection uses no explicit device.
    var deviceID: String? {
        guard case let .device(id) = self else { return nil }
        return id
    }
}

//
//  MicrophoneDevice.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// An available macOS audio input without retained capture resources.
public struct MicrophoneDevice: Identifiable, Equatable, Sendable {

    /// The stable Core Audio UID accepted by `.device(id:)` and `switchMicrophone(to:)`.
    public let id: String

    /// The system-provided display name.
    public let name: String

    /// Whether this input was the system default when the list was queried.
    public let isDefault: Bool

    /// Creates a microphone device description.
    public init(
        id: String,
        name: String,
        isDefault: Bool
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

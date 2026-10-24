//
//  CameraDevice.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Describes an available macOS camera without retaining system capture resources.
public struct CameraDevice: Identifiable, Equatable, Sendable {

    /// The system device identifier for creating or switching camera streams.
    public let id: String

    /// The system device display name.
    public let name: String

    /// Whether this device is the system default camera.
    public let isDefault: Bool

    /// The system-reported camera position; external devices may not report one.
    public let position: CameraPosition
}

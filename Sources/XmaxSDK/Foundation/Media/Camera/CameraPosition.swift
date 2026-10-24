//
//  CameraPosition.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The lens position used for camera capture.
public enum CameraPosition: String, CaseIterable, Sendable {

    /// The front camera.
    case front

    /// The rear camera.
    case back

    /// A camera that does not report a front or back position.
    case unspecified
}

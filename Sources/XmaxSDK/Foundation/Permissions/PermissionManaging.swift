//
//  PermissionManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Defines permission checks and requests required by the SDK.
protocol PermissionManaging: Sendable {

    /// Ensures camera access, requesting system permission if not yet determined.
    ///
    /// - Throws: A camera permission error if access is denied, restricted, or authorization fails.
    func ensureCameraPermission() async throws

    /// Ensures microphone access, requesting system permission if not yet determined.
    ///
    /// - Throws: A microphone permission error if access is denied, restricted, or authorization fails.
    func ensureMicrophonePermission() async throws
}

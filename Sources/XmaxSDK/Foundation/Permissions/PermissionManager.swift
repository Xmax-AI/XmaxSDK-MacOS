//
//  PermissionManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Checks and requests camera and microphone permissions required by the SDK.
final class PermissionManager: PermissionManaging, Sendable {

    /// The platform authorization client.
    private let authorizationClient: PermissionAuthorizationClient

    /// Creates a media permission manager.
    init(
        authorizationClient: PermissionAuthorizationClient = .live
    ) {
        self.authorizationClient = authorizationClient
    }

    /// Ensures camera access, requesting system permission if not yet determined.
    ///
    /// - Throws: A camera permission error if access is denied, restricted, or authorization fails.
    func ensureCameraPermission() async throws {
        try await ensurePermission(
            .camera,
            errorCode: .cameraPermissionDenied,
            errorMessage: "Camera permission is unavailable or was denied"
        )
    }

    /// Ensures microphone access, requesting system permission if not yet determined.
    ///
    /// - Throws: A microphone permission error if access is denied, restricted, or authorization fails.
    func ensureMicrophonePermission() async throws {
        try await ensurePermission(
            .microphone,
            errorCode: .microphonePermissionDenied,
            errorMessage: "Microphone permission is unavailable or was denied"
        )
    }

    /// Checks permission, requests authorization when needed, and reports the corresponding error if unauthorized.
    ///
    /// - Parameters:
    ///   - permission: The required media permission.
    ///   - errorCode: The SDK error code for unauthorized access.
    ///   - errorMessage: The error description for unauthorized access.
    ///
    /// - Throws: The specified permission error if access is restricted, denied, or the request fails.
    private func ensurePermission(
        _ permission: MediaPermission,
        errorCode: XmaxErrorCode,
        errorMessage: String
    ) async throws {
        switch authorizationClient.authorizationStatus(permission) {
        case .authorized:
            return
        case .notDetermined:
            do {
                if try await authorizationClient.requestAccess(permission) {
                    return
                }
            } catch {
                XmaxLogger.permission.error(
                    message:
                        "权限申请失败 (Permission Request Failed)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)"
                )
            }
        case .restricted, .denied:
            break
        }

        throw XmaxError(
            code: errorCode,
            message: errorMessage
        )
    }
}

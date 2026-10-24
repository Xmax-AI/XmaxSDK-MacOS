//
//  PermissionAuthorizationClient.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AVFoundation

/// Media permissions checked by the SDK.
enum MediaPermission: Equatable, Sendable {

    /// Camera capture permission.
    case camera

    /// Microphone capture permission.
    case microphone
}

/// Neutral authorization states for platform media permissions.
enum MediaAuthorizationStatus: Sendable {

    /// The user has not made an authorization choice.
    case notDetermined

    /// Access is restricted by the system.
    case restricted

    /// The user denied access.
    case denied

    /// The user granted access.
    case authorized
}

/// Provides platform media permission queries and asynchronous authorization.
struct PermissionAuthorizationClient: Sendable {

    /// Returns the current media authorization status.
    let authorizationStatus:
        @Sendable (
            _ permission: MediaPermission
        ) -> MediaAuthorizationStatus

    /// Requests media access and returns whether it was granted.
    let requestAccess:
        @Sendable (
            _ permission: MediaPermission
        ) async throws -> Bool

    /// An AVFoundation media permission client.
    static let live = PermissionAuthorizationClient(
        authorizationStatus: { permission in
            let status = AVCaptureDevice.authorizationStatus(
                for: permission.mediaType
            )
            switch status {
            case .notDetermined:
                return .notDetermined
            case .restricted:
                return .restricted
            case .denied:
                return .denied
            case .authorized:
                return .authorized
            @unknown default:
                return .denied
            }
        },
        requestAccess: { permission in
            await AVCaptureDevice.requestAccess(for: permission.mediaType)
        }
    )
}

private extension MediaPermission {

    /// The AVFoundation media type for this permission.
    var mediaType: AVMediaType {
        switch self {
        case .camera:
            return .video
        case .microphone:
            return .audio
        }
    }
}

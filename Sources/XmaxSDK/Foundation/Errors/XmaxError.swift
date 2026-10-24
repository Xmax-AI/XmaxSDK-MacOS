//
//  XmaxError.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Internal listener for unified SDK errors.
typealias XmaxErrorListener = @Sendable (XmaxError) -> Void

/// Unified error codes exposed to callers.
public enum XmaxErrorCode: String, CaseIterable, Sendable {

    /// The API key is missing or empty.
    case invalidAPIKey = "INVALID_API_KEY"

    /// Arguments, configuration, or lifecycle state do not satisfy the operation requirements.
    case invalidConfiguration = "INVALID_CONFIGURATION"

    /// An unexpected, unclassified internal SDK error.
    case internalError = "INTERNAL_ERROR"

    /// The network is unavailable, connection failed, or an HTTP request could not complete.
    case networkError = "NETWORK_ERROR"

    /// The Xmax API reported a business failure or its response could not be parsed.
    case apiError = "API_ERROR"

    /// Realtime session data is missing, the session is closed, or heartbeat state is abnormal.
    case sessionError = "SESSION_ERROR"

    /// An RTC engine, room, media transport, or render binding error.
    case rtcError = "RTC_ERROR"

    /// A local media read, decode, synchronization, or frame processing error.
    case mediaError = "MEDIA_ERROR"

    /// Remote video interpolation is unsupported by the system, device, or video format.
    case frameInterpolationUnsupported =
        "FRAME_INTERPOLATION_UNSUPPORTED"

    /// The caller has not granted camera permission.
    case cameraPermissionDenied = "CAMERA_PERMISSION_DENIED"

    /// The caller has not granted microphone permission.
    case microphonePermissionDenied = "MICROPHONE_PERMISSION_DENIED"

    /// File or binary data upload failed.
    case uploadError = "UPLOAD_ERROR"

    /// Remote file download failed.
    case downloadError = "DOWNLOAD_ERROR"

    /// The image failed content safety checks.
    case unsafeImage = "UNSAFE_IMAGE"

    /// Normal cancellation due to lifecycle change or an explicit caller request.
    case cancelled = "CANCELLED"

    /// A connection, room event, or generation result exceeded its wait timeout.
    case timeout = "TIMEOUT"
}

/// The unified error thrown or reported to SDK callers.
public struct XmaxError: Error, LocalizedError, Equatable, Sendable {

    /// The unified SDK error code.
    public let code: XmaxErrorCode

    /// A readable error description for callers.
    public let message: String

    /// The Xmax API business error code; absent for other errors.
    public let apiCode: Int?

    /// The HTTP response status code; absent if no response was received.
    public let httpStatus: Int?

    /// Creates an SDK error.
    public init(
        code: XmaxErrorCode,
        message: String,
        apiCode: Int? = nil,
        httpStatus: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.apiCode = apiCode
        self.httpStatus = httpStatus
    }

    /// The error description used by `LocalizedError`.
    public var errorDescription: String? {
        message
    }

    /// Converts unknown errors to internal SDK errors, preserving existing `XmaxError` values.
    ///
    /// - Parameter error: The error to convert.
    ///
    /// - Returns: The unified error to throw or report to callers.
    public static func from(
        _ error: any Error
    ) -> XmaxError {
        if let xmaxError = error as? XmaxError {
            return xmaxError
        }

        let description = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty ? String(describing: error) : description

        return XmaxError(
            code: .internalError,
            message: message
        )
    }
}

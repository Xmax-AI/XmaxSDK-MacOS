//
//  RealtimeVideoFormat.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Realtime video encoding strategy preferences.
public enum RealtimeVideoEncoderPreference: Equatable, Sendable {

    /// Balances frame rate and resolution.
    case auto

    /// Prioritizes frame rate.
    case maintainFramerate

    /// Prioritizes resolution.
    case maintainQuality
}

/// Realtime video dimensions, frame rate, and upstream encoding configuration.
public struct RealtimeVideoFormat: Equatable, Sendable {

    /// The video width in pixels.
    public let width: Int

    /// The video height in pixels.
    public let height: Int

    /// The video frame rate.
    public let fps: Int

    /// The upstream encoder minimum in kbps; `nil` uses 500 capped by the resolved maximum, and 0 removes the minimum.
    public let minimumBitrate: Int?

    /// The maximum upstream bitrate in kbps; nil uses the SDK default, explicit values must be positive.
    public let maximumBitrate: Int?

    /// The upstream encoding preference; prioritizes frame rate by default.
    public let encoderPreference: RealtimeVideoEncoderPreference

    /// Creates a realtime video format.
    public init(
        width: Int,
        height: Int,
        fps: Int,
        minimumBitrate: Int? = nil,
        maximumBitrate: Int? = nil,
        encoderPreference: RealtimeVideoEncoderPreference = .maintainFramerate
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.minimumBitrate = minimumBitrate
        self.maximumBitrate = maximumBitrate
        self.encoderPreference = encoderPreference
    }

    /// Validates dimensions, frame rate, and explicit bitrate bounds.
    ///
    /// - Throws: An error if dimensions, frame rate, or bitrate configuration is invalid.
    public func validate() throws {
        guard width > 0,
            height > 0,
            fps > 0,
            width.isMultiple(of: 2),
            height.isMultiple(of: 2)
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Realtime video width and height must be positive "
                    + "even numbers, and fps must be greater than zero"
            )
        }
        if let minimumBitrate, minimumBitrate < 0 {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Minimum bitrate must not be negative"
            )
        }
        if let maximumBitrate, maximumBitrate <= 0 {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Maximum bitrate must be greater than zero"
            )
        }
        if let minimumBitrate, let maximumBitrate, minimumBitrate > maximumBitrate {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Minimum bitrate must not exceed maximum bitrate"
            )
        }
    }
}

extension RealtimeVideoFormat {

    /// Creates a resized video format retaining frame rate and encoding configuration.
    ///
    /// - Parameters:
    ///   - width: The target width in pixels.
    ///   - height: The target height in pixels.
    ///
    /// - Returns: The new video format with target dimensions.
    func resized(
        width: Int,
        height: Int
    ) -> RealtimeVideoFormat {
        RealtimeVideoFormat(
            width: width,
            height: height,
            fps: fps,
            minimumBitrate: minimumBitrate,
            maximumBitrate: maximumBitrate,
            encoderPreference: encoderPreference
        )
    }
}

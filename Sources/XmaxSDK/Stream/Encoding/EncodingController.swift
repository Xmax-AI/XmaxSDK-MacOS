//
//  EncodingController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Configures RTC encoding from the realtime video format.
final class EncodingController: EncodingControlling, Sendable {

    /// The RTC encoder configuration target.
    private let rtcManager: any RtcManaging

    /// Creates a controller applying RTC video encoding configuration.
    init(
        rtcManager: any RtcManaging
    ) {
        self.rtcManager = rtcManager
    }

    /// Validates four-pixel-aligned dimensions and applies RTC encoding parameters.
    ///
    /// An unspecified encoder minimum uses 500 kbps, capped by the resolved maximum.
    ///
    /// - Parameter videoFormat: The format containing dimensions, frame rate, optional bitrate, and encoding
    ///   preferences.
    ///
    /// - Throws: An error on invalid format, default bitrate resolution failure, or RTC configuration failure.
    func configure(
        _ videoFormat: RealtimeVideoFormat
    ) throws {
        try videoFormat.validate()

        guard videoFormat.width.isMultiple(of: 4), videoFormat.height.isMultiple(of: 4) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Uplink video width and height must be multiples of 4"
            )
        }
        let budget = try EncodingBitratePolicy.resolve(videoFormat)
        let maximum = budget.maximum
        let minimum = videoFormat.minimumBitrate ?? min(500, maximum)

        let encoderPreference: VideoEncodingConfiguration.EncoderPreference =
            switch videoFormat.encoderPreference {
            case .auto: .auto
            case .maintainFramerate: .maintainFramerate
            case .maintainQuality: .maintainQuality
            }

        try rtcManager.configureVideoEncoding(
            VideoEncodingConfiguration(
                width: videoFormat.width,
                height: videoFormat.height,
                frameRate: videoFormat.fps,
                minimumBitrate: minimum,
                maximumBitrate: maximum,
                encoderPreference: encoderPreference
            )
        )
    }
}

//
//  VideoEncodingConfiguration.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// RTC primary video stream encoding parameters.
struct VideoEncodingConfiguration: Equatable, Sendable {

    /// Defines video encoding degradation preferences under limited network conditions.
    enum EncoderPreference: Equatable, Sendable {

        /// Lets the RTC engine choose a degradation strategy.
        case auto

        /// Preserves frame rate when bandwidth is limited.
        case maintainFramerate

        /// Preserves picture quality when bandwidth is limited.
        case maintainQuality
    }

    /// The encoding width, in pixels.
    let width: Int

    /// The target encoding height, in pixels.
    let height: Int

    /// The target encoding frame rate, in frames per second.
    let frameRate: Int

    /// The minimum bitrate, in kbps. Zero disables the minimum.
    let minimumBitrate: Int

    /// The maximum bitrate, in kbps. Negative values use the platform default.
    let maximumBitrate: Int

    /// The encoding fallback preference under network or performance constraints.
    let encoderPreference: EncoderPreference

    /// Creates RTC video encoding configuration.
    init(
        width: Int,
        height: Int,
        frameRate: Int,
        minimumBitrate: Int = 0,
        maximumBitrate: Int = -1,
        encoderPreference: EncoderPreference = .maintainFramerate
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.minimumBitrate = minimumBitrate
        self.maximumBitrate = maximumBitrate
        self.encoderPreference = encoderPreference
    }
}

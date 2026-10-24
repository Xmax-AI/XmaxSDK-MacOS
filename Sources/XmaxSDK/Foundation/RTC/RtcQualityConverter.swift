//
//  RtcQualityConverter.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit

/// Converts Agora quality events to neutral quality models.
enum RtcQualityConverter {

    /// Converts Agora local video statistics to SDK upstream metrics.
    ///
    /// - Parameter stats: The Agora upstream statistics.
    ///
    /// - Returns: Upstream statistics with invalid metrics represented by `nil`.
    static func uplinkVideoStatistics(
        _ stats: AgoraRtcLocalVideoStats
    ) -> UplinkVideoStatistics {
        UplinkVideoStatistics(
            width: stats.encodedFrameWidth > 0 ? stats.encodedFrameWidth : nil,
            height: stats.encodedFrameHeight > 0 ? stats.encodedFrameHeight : nil,
            captureFrameRate: nonnegative(stats.captureFrameRate),
            encodeFrameRate: nonnegative(stats.encoderOutputFrameRate),
            sendFrameRate: Int(exactly: stats.sentFrameRate),
            bitrateKbps: Int(exactly: stats.sentBitrate),
            packetLossPercent: (0...100).contains(stats.txPacketLossRate) ? stats.txPacketLossRate : nil
        )
    }

    /// Converts Agora remote video statistics to SDK downstream metrics.
    ///
    /// - Parameters:
    ///   - userID: The remote user account.
    ///   - stats: The Agora downstream statistics.
    ///
    /// - Returns: Downstream statistics associated with a remote account, with invalid metrics represented by `nil`.
    static func downlinkVideoStatistics(
        userID: String,
        _ stats: AgoraRtcRemoteVideoStats
    ) -> DownlinkVideoStatistics {
        DownlinkVideoStatistics(
            userID: userID,
            width: stats.width > 0 ? Int(exactly: stats.width) : nil,
            height: stats.height > 0 ? Int(exactly: stats.height) : nil,
            decodeFrameRate: nonnegative(stats.decoderOutputFrameRate),
            renderFrameRate: nonnegative(stats.rendererOutputFrameRate),
            bitrateKbps: Int(exactly: stats.receivedBitrate),
            packetLossPercent: (0...100).contains(stats.packetLossRate) ? stats.packetLossRate : nil,
            endToEndDelayMs: Int(exactly: stats.e2eDelay)
        )
    }

    /// Preserves nonnegative statistics and rejects negative values.
    ///
    /// - Parameter value: The statistic to validate.
    ///
    /// - Returns: The original nonnegative value; `nil` for negative values.
    private static func nonnegative(
        _ value: Int
    ) -> Int? {
        value >= 0 ? value : nil
    }

    /// Converts Agora network quality to SDK quality levels.
    ///
    /// - Parameter quality: The Agora network quality level.
    ///
    /// - Returns: The corresponding SDK level; `.unknown` for unknown values.
    static func convertLevel(
        _ quality: AgoraNetworkQuality
    ) -> RtcQualityLevel {
        RtcQualityLevel(rawValue: Int(quality.rawValue)) ?? .unknown
    }
}

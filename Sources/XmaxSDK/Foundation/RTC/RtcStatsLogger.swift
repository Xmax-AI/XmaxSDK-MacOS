//
//  RtcStatsLogger.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Writes Agora RTC runtime statistics to consistent Xmax debug logs.
enum RtcStatsLogger {

    /// Logs upstream video metrics when performance logging is enabled.
    ///
    /// - Parameter video: The current upstream video statistics.
    static func logUplinkVideoStatistics(
        _ video: UplinkVideoStatistics
    ) {
        XmaxLogger.rtc.debug(
            message: uplinkVideoStatisticsMessage(video),
            option: .performance
        )
    }

    /// Formats upstream statistics logs.
    ///
    /// - Parameter video: The current upstream video statistics.
    ///
    /// - Returns: The upstream log body with localized field names.
    static func uplinkVideoStatisticsMessage(
        _ video: UplinkVideoStatistics
    ) -> String {
        """
        视频上行统计 (Video Uplink Statistics)
        ├─ \(XmaxLogger.localized("分辨率：", "Resolution: "))\(resolution(video.width, video.height))
        ├─ \(XmaxLogger.localized("发送码率：", "Send Bitrate: "))\(value(video.bitrateKbps, unit: "kbps"))
        ├─ \(XmaxLogger.localized("采集帧率：", "Capture Frame Rate: "))\(value(video.captureFrameRate, unit: "fps"))
        ├─ \(XmaxLogger.localized("编码帧率：", "Encode Frame Rate: "))\(value(video.encodeFrameRate, unit: "fps"))
        ├─ \(XmaxLogger.localized("发送帧率：", "Send Frame Rate: "))\(value(video.sendFrameRate, unit: "fps"))
        └─ \(XmaxLogger.localized("视频丢包率：", "Video Packet Loss: "))\(value(video.packetLossPercent, unit: "%"))
        """
    }

    /// Logs downstream video metrics when performance logging is enabled.
    ///
    /// - Parameter video: The current downstream video statistics.
    static func logDownlinkVideoStatistics(
        _ video: DownlinkVideoStatistics
    ) {
        XmaxLogger.rtc.debug(
            message: downlinkVideoStatisticsMessage(video),
            option: .performance
        )
    }

    /// Formats downstream statistics logs.
    ///
    /// - Parameter video: The current downstream video statistics.
    ///
    /// - Returns: The downstream log body with localized field names.
    static func downlinkVideoStatisticsMessage(
        _ video: DownlinkVideoStatistics
    ) -> String {
        """
        视频下行统计 (Video Downlink Statistics)
        ├─ \(XmaxLogger.localized("分辨率：", "Resolution: "))\(resolution(video.width, video.height))
        ├─ \(XmaxLogger.localized("接收码率：", "Receive Bitrate: "))\(value(video.bitrateKbps, unit: "kbps"))
        ├─ \(XmaxLogger.localized("解码帧率：", "Decode Frame Rate: "))\(value(video.decodeFrameRate, unit: "fps"))
        ├─ \(XmaxLogger.localized("渲染帧率：", "Render Frame Rate: "))\(value(video.renderFrameRate, unit: "fps"))
        ├─ \(XmaxLogger.localized("视频丢包率：", "Video Packet Loss: "))\(value(video.packetLossPercent, unit: "%"))
        └─ \(XmaxLogger.localized("端到端时延：", "End-to-End Delay: "))\(value(video.endToEndDelayMs, unit: "ms"))
        """
    }

    /// Formats available video dimensions.
    ///
    /// - Parameters:
    ///   - width: The pixel width; `nil` when unavailable.
    ///   - height: The pixel height; `nil` when unavailable.
    ///
    /// - Returns: The width and height text, or a placeholder if either value is unavailable.
    private static func resolution(
        _ width: Int?,
        _ height: Int?
    ) -> String {
        guard let width, let height else { return "—" }
        return "\(width) × \(height)"
    }

    /// Appends a unit to available metrics.
    ///
    /// - Parameters:
    ///   - number: The metric value; `nil` when unavailable.
    ///   - unit: The metric unit.
    ///
    /// - Returns: The value with its unit, or an unavailable placeholder.
    private static func value(
        _ number: Int?,
        unit: String
    ) -> String {
        number.map { "\($0) \(unit)" } ?? "—"
    }
}

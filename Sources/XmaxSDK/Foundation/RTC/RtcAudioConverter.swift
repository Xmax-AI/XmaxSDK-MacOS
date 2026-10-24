//
//  RtcAudioConverter.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Validates 48 kHz mono PCM16 data for RTC external audio.
enum RtcAudioConverter {

    /// Validates PCM frame length and returns pushable audio data.
    ///
    /// - Parameter frame: A 10 ms frame of 48 kHz mono PCM16 audio.
    ///
    /// - Returns: The original PCM data after length validation.
    ///
    /// - Throws: An error if audio data length differs from the fixed frame format.
    static func convertFrame(
        _ frame: AudioFrame
    ) throws -> Data {
        let expectedByteCount = AudioFrame.samplesPerFrame * AudioFrame.channelCount * MemoryLayout<Int16>.size
        guard frame.data.count == expectedByteCount else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Audio frame must contain exactly \(expectedByteCount) bytes"
            )
        }
        return frame.data
    }
}

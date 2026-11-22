//
//  AudioFrame.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import Foundation

/// A 48 kHz mono PCM frame for the RTC external audio pipeline.
struct AudioFrame: Equatable, Sendable {

    /// The sample rate, fixed at 48000 Hz.
    static let sampleRate = 48_000

    /// The channel count, fixed at one.
    static let channelCount = 1

    /// The samples per frame, representing 10 ms at 48 kHz.
    static let samplesPerFrame = 480

    /// The 48 kHz mono PCM16 data.
    let data: Data

    /// The timestamp on the shared playback timeline, in microseconds.
    let timestampUs: Int64

    /// Preserves packet timing and falls back to the captured PCM for an absent or invalid result.
    func processed(
        by processor: RealtimeMicrophoneAudioProcessor?
    ) -> AudioFrame {
        guard let processor else { return self }
        let packet = RealtimeAudioFrame(
            data: data,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            samplesPerChannel: Self.samplesPerFrame,
            presentationTimeStamp: CMTime(value: timestampUs, timescale: 1_000_000)
        )
        guard let processed = processor(packet), processed.count == data.count else { return self }
        return AudioFrame(data: processed, timestampUs: timestampUs)
    }
}

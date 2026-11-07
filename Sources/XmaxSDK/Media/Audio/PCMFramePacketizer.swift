//
//  PCMFramePacketizer.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Packetizes contiguous mono PCM16 into 10 ms RTC frames.
struct PCMFramePacketizer {

    /// The bytes per 10 ms packet.
    private static let frameByteCount = AudioFrame.samplesPerFrame * MemoryLayout<Int16>.size

    /// The PCM data for packets not yet drained.
    private var pending = Data()

    /// The first unread byte in the pending data.
    private var readOffset = 0

    /// The number of samples emitted since the start of the segment.
    private var sampleOffset = 0

    /// Appends a contiguous block of mono PCM16 samples.
    mutating func append(
        _ data: Data
    ) {
        if pending.isEmpty {
            pending = data
        } else {
            if readOffset > 0 {
                pending.removeFirst(readOffset)
                readOffset = 0
            }
            pending.append(data)
        }
    }

    /// Returns the next complete packet and its offset in the current segment.
    mutating func nextFrame() -> (data: Data, sampleOffset: Int)? {
        guard pending.count - readOffset >= Self.frameByteCount else { return nil }
        let start = pending.startIndex + readOffset
        let data = Data(pending[start..<start + Self.frameByteCount])
        let offset = sampleOffset
        readOffset += Self.frameByteCount
        if readOffset == pending.count {
            pending = Data()
            readOffset = 0
        }
        sampleOffset += AudioFrame.samplesPerFrame
        return (data, offset)
    }
}

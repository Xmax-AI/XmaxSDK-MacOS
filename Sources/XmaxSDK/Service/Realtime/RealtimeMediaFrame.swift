//
//  RealtimeMediaFrame.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import Foundation

/// An owned packet of signed, little-endian, interleaved 16-bit PCM.
public struct RealtimeAudioFrame: Sendable {

    /// The copied PCM bytes, safe to retain after the callback returns.
    public let data: Data

    /// The number of samples per second in each channel.
    public let sampleRate: Int

    /// The number of interleaved audio channels.
    public let channels: Int

    /// The number of samples in each channel of this packet.
    public let samplesPerChannel: Int

    /// The first sample's time on the same timeline as the corresponding video track.
    public let presentationTimeStamp: CMTime

    /// The exact packet duration, calculated from its sample count and sample rate.
    public var duration: CMTime {
        CMTime(
            value: Int64(samplesPerChannel),
            timescale: Int32(sampleRate)
        )
    }

    /// Creates an owned audio packet with a resolved presentation time.
    init(
        data: Data,
        sampleRate: Int,
        channels: Int,
        samplesPerChannel: Int,
        presentationTimeStamp: CMTime
    ) {
        self.data = data
        self.sampleRate = sampleRate
        self.channels = channels
        self.samplesPerChannel = samplesPerChannel
        self.presentationTimeStamp = presentationTimeStamp
    }
}

/// One audio or video packet, with a shared stream identity and time basis.
///
/// Events are serialized in delivery order, not sorted by presentation time across tracks. Video
/// processing can delay delivery relative to audio. Buffer and schedule both tracks by their PTS;
/// use one recording origin for both. An event does not represent an audio/video pair.
/// Treat video pixel buffers as read-only because rendering may share them.
public struct RealtimeMediaFrame: Sendable {

    /// The media carried by an output event.
    public enum Content: Sendable {

        /// Microphone PCM or result PCM before remote-user mixing.
        case audio(RealtimeAudioFrame)

        /// A camera frame before RTC encoding or a result frame after SDK processing.
        case video(RealtimeVideoFrame)
    }

    /// An opaque identity shared by both tracks of a local camera stream or a result-stream binding.
    ///
    /// A new camera stream or result binding receives a new identity.
    public let streamID: UUID

    /// Whether this track begins a run, changes format or clock, or follows discarded output.
    ///
    /// The first event of each track is marked. Later discontinuities require your app to handle
    /// the gap or start a new recording segment. Output-queue loss does not compress the timeline.
    public let isDiscontinuous: Bool

    /// The audio or video carried by the event.
    public let content: Content

    /// The packet's presentation time, which does not necessarily start at zero.
    public var presentationTimeStamp: CMTime {
        switch content {
        case .audio(let frame): frame.presentationTimeStamp
        case .video(let frame): frame.presentationTimeStamp
        }
    }

    /// The audio duration or suggested video duration; video duration may be `.invalid`.
    public var duration: CMTime {
        switch content {
        case .audio(let frame): frame.duration
        case .video(let frame): frame.duration
        }
    }

    /// Creates a media event.
    init(
        streamID: UUID,
        isDiscontinuous: Bool,
        content: Content
    ) {
        self.streamID = streamID
        self.isDiscontinuous = isDiscontinuous
        self.content = content
    }
}

/// A serialized background handler for PCM and video.
public typealias RealtimeMediaFrameListener = @Sendable (RealtimeMediaFrame) -> Void

/// The captured tracks requested by a local media frame listener.
public enum RealtimeMediaTrack: Hashable, Sendable {

    /// The microphone paired with the local camera stream.
    case audio

    /// Video captured by the local camera stream.
    case video
}

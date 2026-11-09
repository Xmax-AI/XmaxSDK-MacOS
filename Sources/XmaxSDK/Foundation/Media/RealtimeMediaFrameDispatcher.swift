//
//  RealtimeMediaFrameDispatcher.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import CoreVideo
import Foundation

/// Serializes bounded media delivery independently of capture, RTC audio, and rendering.
final class RealtimeMediaFrameDispatcher: @unchecked Sendable {

    /// Protects stream identity, timeline state, listener revisions, and queue admission.
    private let lock = NSLock()

    /// The background queue invoking application callbacks.
    private let queue: DispatchQueue

    /// The largest number of retained packets, including a callback currently running.
    private let maximumPendingFrames: Int

    /// The largest retained media size, including a callback currently running.
    private let maximumPendingBytes: Int

    /// The video retention limit, independently of pending PCM.
    private let maximumPendingVideoFrames: Int

    /// The current application callback.
    private var listener: RealtimeMediaFrameListener?

    /// The tracks requested by the current listener.
    private var tracks: Set<RealtimeMediaTrack> = [.audio, .video]

    /// The revision rejecting output queued for a removed or replaced listener.
    private var version: UInt64 = 0

    /// The binding token shared by current audio and video producers.
    private var streamID: UUID?

    /// The sample-based audio rendering timeline.
    private var audioTimeline = RemoteAudioTimeline()

    /// The expected start of the next captured microphone packet, in microseconds.
    private var nextLocalAudioTimestamp: Int64?

    /// Rejects queued microphone packets after capture stops while video remains active.
    private var audioVersion: UInt64 = 0

    /// The previous video PTS, used to expose backward clock changes.
    private var lastVideoPTS: CMTime?

    /// The previous video dimensions and pixel format, used to expose encoding format changes.
    private var lastVideoFormat: [Int]?

    /// Whether the next admitted audio packet must report a discontinuity.
    private var audioDiscontinuous = true

    /// Whether the next admitted video frame must report a discontinuity.
    private var videoDiscontinuous = true

    /// The number of retained delivery operations across all revisions.
    private var pendingFrames = 0

    /// The media retained by delivery operations across all revisions.
    private var pendingBytes = 0

    /// The number of video buffers retained by queued or running callbacks.
    private var pendingVideoFrames = 0

    /// Whether an application currently requests media output.
    var hasListener: Bool {
        lock.withLock { listener != nil }
    }

    /// Creates a bounded output queue.
    init(
        maximumPendingFrames: Int = 256,
        maximumPendingBytes: Int = 32 * 1_024 * 1_024,
        maximumPendingVideoFrames: Int = .max,
        deliveryQueue: DispatchQueue = DispatchQueue(
            label: "ai.xmax.sdk.remote-media-frame",
            qos: .userInitiated
        )
    ) {
        self.maximumPendingFrames = maximumPendingFrames
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumPendingVideoFrames = maximumPendingVideoFrames
        queue = deliveryQueue
    }

    /// Replaces the listener and rejects queued output from the previous listener.
    ///
    /// - Parameters:
    ///   - listener: The media callback, or `nil` to stop delivery.
    ///   - tracks: The media to deliver to the callback.
    func setListener(
        _ listener: RealtimeMediaFrameListener?,
        tracks: Set<RealtimeMediaTrack> = [.audio, .video]
    ) {
        lock.withLock {
            version &+= 1
            self.listener = listener
            self.tracks = tracks
            resetTimeline()
        }
    }

    /// Starts a new binding, invalidating packets from all previous producers.
    ///
    /// - Parameter active: Whether a media stream is bound.
    ///
    /// - Returns: The new stream identity, or `nil` after unbinding.
    @discardableResult
    func setStream(
        active: Bool
    ) -> UUID? {
        lock.withLock {
            version &+= 1
            streamID = active ? UUID() : nil
            resetTimeline()
            return streamID
        }
    }

    /// Invalidates queued microphone packets while retaining the video binding.
    func resetLocalAudio() {
        lock.withLock {
            audioVersion &+= 1
            nextLocalAudioTimestamp = nil
            audioDiscontinuous = true
        }
    }

    /// Enqueues SDK-owned microphone PCM without changing its capture timestamp.
    func dispatchLocalAudio(
        _ frame: AudioFrame,
        streamID: UUID
    ) {
        lock.withLock {
            guard self.streamID == streamID, listener != nil, tracks.contains(.audio) else { return }
            let gap = nextLocalAudioTimestamp.map { abs(frame.timestampUs - $0) > 1 } ?? true
            let packetDuration = AudioFrame.samplesPerFrame * 1_000_000 / AudioFrame.sampleRate
            nextLocalAudioTimestamp = frame.timestampUs + Int64(packetDuration)
            let audio = RealtimeAudioFrame(
                data: frame.data,
                sampleRate: AudioFrame.sampleRate,
                channels: AudioFrame.channelCount,
                samplesPerChannel: AudioFrame.samplesPerFrame,
                presentationTimeStamp: CMTime(value: frame.timestampUs, timescale: 1_000_000)
            )
            let output = RealtimeMediaFrame(
                streamID: streamID,
                isDiscontinuous: audioDiscontinuous || gap,
                content: .audio(audio)
            )
            audioDiscontinuous = !enqueue(output, bytes: frame.data.count, track: .audio)
        }
    }

    /// Normalizes audio on the producer thread and enqueues only a current binding's packets.
    ///
    /// - Parameters:
    ///   - frame: The copied PCM packet and native rendering timestamp.
    ///   - streamID: The token identifying the producer's result-stream binding.
    func dispatchAudio(
        _ frame: RtcRemoteAudioFrame,
        streamID: UUID
    ) {
        lock.withLock {
            guard self.streamID == streamID, listener != nil, tracks.contains(.audio) else {
                return
            }
            guard let resolved = audioTimeline.resolve(frame) else {
                audioDiscontinuous = true
                return
            }

            let output = RealtimeMediaFrame(
                streamID: streamID,
                isDiscontinuous: audioDiscontinuous || resolved.discontinuous,
                content: .audio(resolved.frame)
            )
            audioDiscontinuous = !enqueue(
                output,
                bytes: frame.data.count,
                track: .audio
            )
        }
    }

    /// Enqueues video while preserving its capture or rendering PTS.
    ///
    /// - Parameters:
    ///   - frame: The video frame and presentation timestamp.
    ///   - streamID: The token identifying the producer's stream binding.
    func dispatchVideo(
        _ frame: RealtimeVideoFrame,
        streamID: UUID
    ) {
        lock.withLock {
            guard self.streamID == streamID, listener != nil, tracks.contains(.video) else {
                return
            }
            guard frame.presentationTimeStamp.isNumeric else {
                videoDiscontinuous = true
                return
            }

            let backwards = lastVideoPTS.map { frame.presentationTimeStamp <= $0 } ?? false
            let format = [
                CVPixelBufferGetWidth(frame.pixelBuffer),
                CVPixelBufferGetHeight(frame.pixelBuffer),
                Int(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))
            ]
            let formatChanged = lastVideoFormat.map { $0 != format } ?? false
            lastVideoPTS = frame.presentationTimeStamp
            lastVideoFormat = format

            let output = RealtimeMediaFrame(
                streamID: streamID,
                isDiscontinuous: videoDiscontinuous || backwards || formatChanged,
                content: .video(frame)
            )

            videoDiscontinuous = !enqueue(
                output,
                bytes: CVPixelBufferGetDataSize(frame.pixelBuffer),
                track: .video
            )
        }
    }

    /// Resets both tracks without changing the binding identity. Requires `lock`.
    private func resetTimeline() {
        audioTimeline.reset()
        nextLocalAudioTimestamp = nil
        lastVideoPTS = nil
        lastVideoFormat = nil
        audioDiscontinuous = true
        videoDiscontinuous = true
    }

    /// Admits one bounded callback in producer order. Requires `lock`.
    ///
    /// - Parameters:
    ///   - frame: The audio or video packet to deliver.
    ///   - bytes: The number of media bytes retained by this packet.
    ///   - track: The track whose retention and delivery revision apply.
    ///
    /// - Returns: Whether the packet was admitted within the frame and byte limits.
    private func enqueue(
        _ frame: RealtimeMediaFrame,
        bytes: Int,
        track: RealtimeMediaTrack
    ) -> Bool {
        let isVideo = track == .video
        guard pendingFrames < maximumPendingFrames, bytes <= maximumPendingBytes - pendingBytes,
              !isVideo || pendingVideoFrames < maximumPendingVideoFrames else {
            return false
        }

        pendingFrames += 1
        pendingBytes += bytes
        if isVideo { pendingVideoFrames += 1 }
        let revision = version
        let audioRevision = audioVersion

        queue.async { [weak self] in
            guard let self else {
                return
            }
            defer {
                lock.withLock {
                    pendingFrames -= 1
                    pendingBytes -= bytes
                    if isVideo { pendingVideoFrames -= 1 }
                }
            }

            let callback: RealtimeMediaFrameListener? = lock.withLock {
                guard version == revision, streamID == frame.streamID,
                      isVideo || audioVersion == audioRevision else { return nil }
                return listener
            }
            if let callback {
                callback(frame)
            }
        }

        return true
    }
}

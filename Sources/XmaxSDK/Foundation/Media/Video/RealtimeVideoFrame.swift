//
//  RealtimeVideoFrame.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import CoreVideo

/// A video frame after SDK processing in the realtime video pipeline.
public struct RealtimeVideoFrame: @unchecked Sendable {

    /// The current frame pixel buffer.
    ///
    /// The pixel format follows the remote video pipeline. Callers may retain the buffer until asynchronous
    /// encoding completes.
    public let pixelBuffer: CVPixelBuffer

    /// The current frame presentation time on the realtime video timeline.
    ///
    /// Timestamps may not begin at zero; use the first received frame as the recording timeline origin.
    public let presentationTimeStamp: CMTime

    /// The suggested display duration of the current frame.
    public let duration: CMTime

    /// Creates a realtime video frame for display or recording.
    init(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime = .invalid
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
    }
}

/// A listener receiving final remote video frames.
public typealias RealtimeVideoFrameListener =
    @Sendable (
        _ frame: RealtimeVideoFrame
    ) -> Void

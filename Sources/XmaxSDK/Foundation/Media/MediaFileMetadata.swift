//
//  MediaFileMetadata.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Video, audio, and timeline metadata for a local media file.
struct MediaFileMetadata: Equatable, Sendable {

    /// The encoded video width, in pixels.
    let width: Int

    /// The encoded video height, in pixels.
    let height: Int

    /// The rotation from encoded pixels to display orientation.
    let rotation: VideoRotation

    /// The media duration, in seconds.
    let durationSeconds: Double

    /// Whether the file contains an audio track.
    let hasAudio: Bool
}

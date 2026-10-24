//
//  RealtimeMediaStream.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// A realtime stream containing local input or remote generated results.
public struct RealtimeMediaStream: Sendable {

    /// The media stream identifier.
    public let id: String

    /// The stream's video track.
    public let videoTrack: RealtimeVideoTrack?
}

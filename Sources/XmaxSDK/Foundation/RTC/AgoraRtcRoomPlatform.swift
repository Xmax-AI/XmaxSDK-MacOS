//
//  AgoraRtcRoomPlatform.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit
import Foundation

/// The room's engine operations are serialized separately from its callback state.
protocol AgoraRtcRoomPlatform: AnyObject, Sendable {

    /// The native channel operation interface.
    var roomEngine: any AgoraRtcRoomEngine { get }

    /// The recursive lock serializing room operations and shared engine configuration.
    var lock: NSRecursiveLock { get }

    /// The active custom audio track identifier, when custom audio is configured.
    var audioTrackID: Int? { get }

    /// Whether local video publication uses the native camera track.
    var usesCameraTrack: Bool { get }

    /// Installs the remote frame receiver and returns whether registration succeeds.
    func setRemoteVideoSink(
        _ sink: RtcRemoteVideoSink?
    ) -> Bool

    /// Reapplies stored encoding settings after source or publication changes.
    func reapplyVideoConfiguration() throws
}

extension AgoraRtcRoomPlatform {

    /// Whether local video publication uses the native camera track.
    var usesCameraTrack: Bool { false }

    /// Installs the remote frame receiver and returns whether registration succeeds.
    func setRemoteVideoSink(
        _ sink: RtcRemoteVideoSink?
    ) -> Bool { roomEngine.setVideoFrameDelegate(sink) }
}

/// The native channel, subscription, and signaling operations used by the room adapter.
protocol AgoraRtcRoomEngine: AnyObject {

    /// Installs the engine video frame observer and reports whether it is accepted.
    func setVideoFrameDelegate(
        _ delegate: (any AgoraVideoFrameDelegate)?
    ) -> Bool

    /// Installs or removes the native per-user audio observer.
    func setAudioFrameDelegate(
        _ delegate: (any AgoraAudioFrameDelegate)?
    ) -> Bool

    /// Configures the before-mixing PCM observation format.
    func setPlaybackAudioFrameBeforeMixingParametersWithSampleRate(
        _ sampleRate: Int,
        channel: Int,
        samplesPerCall: Int
    ) -> Int32

    /// Joins a channel using a user account and the supplied event and media configuration.
    func joinChannelEx(
        byToken token: String?,
        channelId: String,
        userAccount: String,
        delegate: (any AgoraRtcEngineDelegate)?,
        mediaOptions: AgoraRtcChannelMediaOptions,
        joinSuccess: ((String, UInt, Int) -> Void)?
    ) -> Int32

    /// Leaves the specified channel connection.
    func leaveChannelEx(
        _ channelId: String,
        userAccount: String,
        leaveChannelBlock: ((AgoraChannelStats) -> Void)?
    ) -> Int32

    /// Updates publication and subscription options for a connection.
    func updateChannelEx(
        with options: AgoraRtcChannelMediaOptions,
        connection: AgoraRtcConnection
    ) -> Int32

    /// Changes the video subscription for a native user in a connection.
    func muteRemoteVideoStreamEx(
        _ uid: UInt,
        mute: Bool,
        connection: AgoraRtcConnection
    ) -> Int32

    /// Changes the audio subscription for a native user in a connection.
    func muteRemoteAudioStreamEx(
        _ uid: UInt,
        mute: Bool,
        connection: AgoraRtcConnection
    ) -> Int32

    /// Sets remote user playback volume in the native range of 0 through 100.
    func adjustUserPlaybackSignalVolumeEx(
        _ uid: UInt,
        volume: Int,
        connection: AgoraRtcConnection
    ) -> Int32

    /// Creates a signaling stream and writes its identifier to the supplied pointer.
    func createDataStreamEx(
        _ streamId: UnsafeMutablePointer<Int>,
        config: AgoraDataStreamConfig,
        connection: AgoraRtcConnection
    ) -> Int32

    /// Sends data on the connection's signaling stream.
    func sendStreamMessageEx(
        _ streamId: Int,
        data: Data,
        connection: AgoraRtcConnection
    ) -> Int32

    /// Resolves user metadata by native identifier or account within the connection.
    func getUserInfo(
        byUidEx uid: UInt,
        connection: AgoraRtcConnection,
        withError error: UnsafeMutablePointer<AgoraErrorCode>?
    ) -> AgoraUserInfo?

    /// Resolves user metadata by native identifier or account within the connection.
    func getUserInfo(
        byUserAccountEx account: String,
        connection: AgoraRtcConnection,
        withError error: UnsafeMutablePointer<AgoraErrorCode>?
    ) -> AgoraUserInfo?
}

extension AgoraRtcEngineKit: AgoraRtcRoomEngine {}

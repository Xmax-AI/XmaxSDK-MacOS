//
//  RtcRoomEventBridge.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@preconcurrency import AgoraRtcKit

/// Forwards one Agora connection's callbacks to the RTC manager.
final class RtcRoomEventBridge: NSObject, AgoraRtcEngineDelegate {

    /// Wraps user, media, and quality events for one Agora connection.
    enum Event: Sendable {

        /// The local user joined with a numeric UID.
        case joined(UInt)

        /// A numeric UID-to-account mapping changed.
        case account(UInt, String)

        /// A remote user's video publication changed.
        case publication(UInt, Bool)

        /// A remote user joined.
        case userJoined(UInt)

        /// An Agora room error and description.
        case failure(String)

        /// A native user's upstream and downstream network quality report.
        case quality(RtcQualityLevel, RtcQualityLevel)

        /// A local video encoding and transmission statistics report.
        case localStats(UplinkVideoStatistics, adaptation: Int, width: Int, height: Int, frameRate: Int)

        /// A remote user's received video statistics report.
        case remoteStats(UInt, DownlinkVideoStatistics)
    }

    /// The converted event handler.
    private let handler: @Sendable (Event) -> Void

    /// Creates a room event bridge.
    init(
        handler: @escaping @Sendable (Event) -> Void
    ) {
        self.handler = handler
    }

    /// Forwards successful local room join events.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - channel: The joined channel identifier.
    ///   - uid: The local user's numeric identifier.
    ///   - elapsed: The duration from join call to success in milliseconds.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didJoinChannel channel: String,
        withUid uid: UInt,
        elapsed: Int
    ) {
        handler(.joined(uid))
    }

    /// Forwards mappings between remote numeric user identifiers and accounts.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - uid: The remote user's numeric identifier.
    ///   - userInfo: The user account information.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didUserInfoUpdatedWithUserId uid: UInt,
        userInfo: AgoraUserInfo
    ) {
        guard let account = userInfo.userAccount, !account.isEmpty else { return }
        handler(
            .account(
                uid,
                account
            )
        )
    }

    /// Forwards remote user join events.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - uid: The joined remote user's numeric identifier.
    ///   - elapsed: The join notification duration in milliseconds.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didJoinedOfUid uid: UInt,
        elapsed: Int
    ) {
        handler(.userJoined(uid))
    }

    /// Reports stopped video publication when a remote user leaves.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - uid: The departing remote user's numeric identifier.
    ///   - reason: The user offline reason.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didOfflineOfUid uid: UInt,
        reason: AgoraUserOfflineReason
    ) {
        handler(
            .publication(
                uid,
                false
            )
        )
    }

    /// Converts remote video mute changes to publication state.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - muted: Whether remote video is muted.
    ///   - uid: The remote user's numeric identifier.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didVideoMuted muted: Bool,
        byUid uid: UInt
    ) {
        handler(
            .publication(
                uid,
                !muted
            )
        )
    }

    /// Converts remote video enablement changes to publication state.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - enabled: Whether remote video is enabled.
    ///   - uid: The remote user's numeric identifier.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didVideoEnabled enabled: Bool,
        byUid uid: UInt
    ) {
        handler(
            .publication(
                uid,
                enabled
            )
        )
    }

    /// Converts remote video enablement changes to publication state.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - enabled: Whether remote video is enabled.
    ///   - uid: The remote user's numeric identifier.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didLocalVideoEnabled enabled: Bool,
        byUid uid: UInt
    ) {
        handler(
            .publication(
                uid,
                enabled
            )
        )
    }

    /// Derives video publication state from remote user status bits.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - uid: The remote user's numeric identifier.
    ///   - state: The remote user's status bits.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        remoteUserStateChangedOfUid uid: UInt,
        state: UInt
    ) {
        // USER_STATE flags from AgoraBase.h reveal remote publication state even before subscription.
        let muteVideo: UInt = 1 << 1
        let enableVideo: UInt = 1 << 4
        let enableLocalVideo: UInt = 1 << 8
        let published = state & muteVideo == 0 && state & enableVideo != 0 && state & enableLocalVideo != 0
        handler(
            .publication(
                uid,
                published
            )
        )
    }

    /// Forwards video publication or stop events based on remote receiving state.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - uid: The remote user's numeric identifier.
    ///   - state: The current video receiving state.
    ///   - reason: The state change reason.
    ///   - elapsed: The state change duration in milliseconds.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        remoteVideoStateChangedOfUid uid: UInt,
        state: AgoraVideoRemoteState,
        reason: AgoraVideoRemoteReason,
        elapsed: Int
    ) {
        if state == .starting || state == .decoding {
            handler(
                .publication(
                    uid,
                    true
                )
            )
        } else if reason == .remoteMuted || reason == .remoteOffline {
            handler(
                .publication(
                    uid,
                    false
                )
            )
        }
    }

    /// Forwards connection errors when RTC connection fails.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - state: The current connection state.
    ///   - reason: The connection state change reason.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        connectionChangedTo state: AgoraConnectionState,
        reason: AgoraConnectionChangedReason
    ) {
        if state == .failed {
            handler(.failure("Agora connection failed: \(reason.rawValue)"))
        }
    }

    /// Reports room connection failure when the token expires.
    ///
    /// - Parameter engine: The RTC engine requesting a new token.
    func rtcEngineRequestToken(
        _ engine: AgoraRtcEngineKit
    ) {
        handler(.failure("Agora RTC token expired"))
    }

    /// Logs errors reported by the Agora engine.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - errorCode: The Agora error code.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        didOccurError errorCode: AgoraErrorCode
    ) {
        XmaxLogger.rtc.error(message: "声网 RTC 错误 (Agora RTC Error)\n└─ \(errorCode.rawValue)")
    }

    /// Forwards local upstream and downstream network quality.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - uid: The user associated with the metrics; zero denotes the local user.
    ///   - txQuality: The upstream network quality.
    ///   - rxQuality: The downstream network quality.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        networkQuality uid: UInt,
        txQuality: AgoraNetworkQuality,
        rxQuality: AgoraNetworkQuality
    ) {
        if uid == 0 {
            handler(
                .quality(
                    RtcQualityConverter.convertLevel(txQuality),
                    RtcQualityConverter.convertLevel(rxQuality)
                )
            )
        }
    }

    /// Forwards local upstream video statistics.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - stats: The current local video statistics.
    ///   - sourceType: The video source type associated with the statistics.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        localVideoStats stats: AgoraRtcLocalVideoStats,
        sourceType: AgoraVideoSourceType
    ) {
        // Snapshot vendor-owned mutable objects before the room handles events asynchronously.
        handler(
            .localStats(
                RtcQualityConverter.uplinkVideoStatistics(stats),
                adaptation: stats.qualityAdaptIndication.rawValue,
                width: stats.encodedFrameWidth,
                height: stats.encodedFrameHeight,
                frameRate: stats.encoderOutputFrameRate
            )
        )
    }

    /// Forwards remote downstream video statistics.
    ///
    /// - Parameters:
    ///   - engine: The RTC engine producing the callback.
    ///   - stats: The current remote video statistics.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        remoteVideoStats stats: AgoraRtcRemoteVideoStats
    ) {
        handler(
            .remoteStats(
                stats.uid,
                RtcQualityConverter.downlinkVideoStatistics(
                    userID: "",
                    stats
                )
            )
        )
    }
}

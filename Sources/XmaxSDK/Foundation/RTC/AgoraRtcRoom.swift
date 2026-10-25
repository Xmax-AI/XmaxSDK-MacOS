//
//  AgoraRtcRoom.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit
import Foundation

/// Wraps one Agora connection, user mappings, publication, subscription, and DataStream signaling.
final class AgoraRtcRoom: RtcRoom, @unchecked Sendable {

    /// The engine adapter and operation lock shared with this room.
    private let platform: any AgoraRtcRoomPlatform

    /// The Agora channel name.
    private let roomID: String

    /// The room's Agora connection.
    let connection = AgoraRtcConnection()

    /// The bridge from Agora callbacks to room events.
    private var bridge: RtcRoomEventBridge?

    /// The decoded frame receiver.
    private var videoSink: RtcRemoteVideoSink?

    /// The per-user PCM receiver retained until room destruction.
    private var audioSink: RtcRemoteAudioSink?

    /// Control state is serialized by platform.lock; Agora callbacks must never wait for it.
    private var accounts: [UInt: String] = [:]

    /// The video publication state of remote users.
    private var publications: [UInt: Bool] = [:]

    /// The callback-visible state accessed without acquiring engine operation locks.
    private struct CallbackState {

        /// Whether callbacks must discard events and frames.
        var isClosed = false

        /// Whether remote frame callbacks may deliver pixels.
        var isJoined = false

        /// The current neutral room event receiver.
        var listener: (@Sendable (RtcRoomEvent) -> Void)?

        /// The remote frame receivers indexed by native user identifier.
        var frameListeners: [UInt: RtcRemoteVideoFrameListener] = [:]

        /// The PCM receivers indexed by native user identifier.
        var audioListeners: [UInt: RtcRemoteAudioFrameListener] = [:]
    }

    /// Only short state access is allowed under this lock, never engine calls or listener invocation.
    private let callbackLock = NSLock()

    /// The callback-visible room state protected by the callback lock.
    private var callbackState = CallbackState()

    /// The serial queue processing native events after their callbacks return.
    private let eventQueue = DispatchQueue(label: "ai.xmax.sdk.agora-room-events")

    /// The signaling data stream identifier.
    private var dataStreamID = 0

    /// The room's signaling queue.
    private var sender: RtcMessageQueue?

    /// The local account, protected by `platform.lock`.
    private var account: String?

    /// Whether room join has completed.
    private(set) var isJoined = false

    /// Whether the room is closed to further operations.
    private(set) var isClosed = false

    /// Creates an Agora room for one connection.
    ///
    /// - Parameters:
    ///   - platform: The platform adapter retaining the Agora engine.
    ///   - roomID: The RTC room identifier.
    init(
        platform: any AgoraRtcRoomPlatform,
        roomID: String
    ) {
        self.platform = platform
        self.roomID = roomID
        connection.channelId = roomID
    }

    /// Sets the room event callback.
    ///
    /// - Parameter listener: The neutral event callback; nil clears it.
    func setEventListener(
        _ listener: (@Sendable (RtcRoomEvent) -> Void)?
    ) {
        callbackLock.withLock {
            callbackState.listener = callbackState.isClosed ? nil : listener
        }
    }

    /// Initiates joining; success is reported through the joined event.
    ///
    /// - Parameter configuration: The room, user account, and token.
    ///
    /// - Throws: An error if the join call fails immediately.
    func join(
        configuration: RoomJoinConfiguration
    ) throws {
        try platform.lock.withLock {
            guard !isClosed, account == nil, configuration.roomID == roomID else {
                throw XmaxError(
                    code: .rtcError,
                    message: "RTC room cannot be joined"
                )
            }
            account = configuration.userID
            let bridge = RtcRoomEventBridge { [weak self] event in
                // Return to Agora immediately; lifecycle handling can acquire control locks or call the engine.
                self?.enqueue(event)
            }
            self.bridge = bridge

            let sink = RtcRemoteVideoSink { [weak self] uid, channelID, frame in
                guard let self else { return }
                let callback = callbackLock.withLock {
                    !callbackState.isClosed && callbackState.isJoined && channelID == roomID
                        ? callbackState.frameListeners[uid] : nil
                }
                callback?(frame)
            }
            videoSink = sink

            let audioSink = RtcRemoteAudioSink { [weak self] uid, channelID in
                guard let self else { return nil }
                return callbackLock.withLock {
                    !callbackState.isClosed && callbackState.isJoined && channelID == roomID
                        ? callbackState.audioListeners[uid] : nil
                }
            }
            self.audioSink = audioSink
            try AgoraRtcPlatform.checkResult(
                platform.roomEngine.setPlaybackAudioFrameBeforeMixingParametersWithSampleRate(
                    48_000,
                    channel: 1,
                    samplesPerCall: 480
                ),
                operation: "configureRemoteAudioFrames"
            )
            guard platform.roomEngine.setAudioFrameDelegate(audioSink) else {
                throw XmaxError(
                    code: .rtcError,
                    message: "Failed to register RTC audio frame observer"
                )
            }

            let options = AgoraRtcChannelMediaOptions()
            options.channelProfile = .liveBroadcasting
            options.clientRoleType = .broadcaster
            options.publishCameraTrack = false
            options.publishCustomVideoTrack = false
            options.publishMicrophoneTrack = false
            options.publishCustomAudioTrack = false
            options.autoSubscribeAudio = false
            options.autoSubscribeVideo = false
            try AgoraRtcPlatform.checkResult(
                platform.roomEngine.joinChannelEx(
                    byToken: configuration.token,
                    channelId: roomID,
                    userAccount: configuration.userID,
                    delegate: bridge,
                    mediaOptions: options,
                    joinSuccess: nil
                ),
                operation: "joinChannelEx"
            )
        }
    }

    /// Stops callbacks, clears signals and frame listeners, and leaves the room; repeated calls are harmless.
    func destroy() {
        // Invalidate callbacks before entering SDK calls that may wait for in-flight callbacks to return.
        callbackLock.withLock { callbackState = CallbackState(isClosed: true) }
        platform.lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            isJoined = false
            sender?.close()
            sender = nil
            accounts.removeAll()
            publications.removeAll()

            if let account {
                _ = platform.setRemoteVideoSink(nil)
                _ = platform.roomEngine.setAudioFrameDelegate(nil)
                _ = platform.roomEngine.leaveChannelEx(
                    roomID,
                    userAccount: account,
                    leaveChannelBlock: nil
                )
            }
            bridge = nil
            videoSink = nil
            audioSink = nil
        }
    }

    /// Updates local video publication state.
    ///
    /// - Parameter publish: Whether to publish the active camera or custom video track.
    ///
    /// - Throws: An error if publication configuration fails.
    func publishLocalVideo(
        _ publish: Bool
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            let options = AgoraRtcChannelMediaOptions()
            options.publishCameraTrack = publish && platform.usesCameraTrack
            options.publishCustomVideoTrack = publish && !platform.usesCameraTrack
            options.customVideoTrackId = 0
            try update(
                options,
                operation: "publishLocalVideo"
            )
            if publish { try platform.reapplyVideoConfiguration() }
        }
    }

    /// Updates local audio publication state.
    ///
    /// - Parameter publish: Whether to publish the current audio source.
    ///
    /// - Throws: An error if publication configuration fails.
    func publishLocalAudio(
        _ publish: Bool
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            let options = AgoraRtcChannelMediaOptions()
            options.publishMicrophoneTrack = publish && platform.audioTrackID == nil
            options.publishCustomAudioTrack = publish && platform.audioTrackID != nil
            if let audioTrackID = platform.audioTrackID {
                options.publishCustomAudioTrackId = audioTrackID
            }
            try update(
                options,
                operation: "publishLocalAudio"
            )
        }
    }

    /// Updates remote video subscription.
    ///
    /// - Parameters:
    ///   - userID: The server-assigned RTC user account.
    ///   - subscribe: Whether to subscribe to video.
    ///
    /// - Throws: An error on user mapping or subscription failure.
    func subscribeRemoteVideo(
        userID: String,
        subscribe: Bool
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            try AgoraRtcPlatform.checkResult(
                platform.roomEngine.muteRemoteVideoStreamEx(
                    try resolveUID(userID),
                    mute: !subscribe,
                    connection: connection
                ),
                operation: "subscribeRemoteVideo"
            )
        }
    }

    /// Updates remote audio subscription.
    ///
    /// - Parameters:
    ///   - userID: The server-assigned RTC user account.
    ///   - subscribe: Whether to subscribe to audio.
    ///
    /// - Throws: An error on user mapping or subscription failure.
    func subscribeRemoteAudio(
        userID: String,
        subscribe: Bool
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            try AgoraRtcPlatform.checkResult(
                platform.roomEngine.muteRemoteAudioStreamEx(
                    try resolveUID(userID),
                    mute: !subscribe,
                    connection: connection
                ),
                operation: "subscribeRemoteAudio"
            )
        }
    }

    /// Sets remote audio playback volume.
    ///
    /// - Parameters:
    ///   - volume: The volume from 0 to 100.
    ///   - userID: The RTC user account.
    ///
    /// - Throws: An error on user mapping or volume configuration failure.
    func setRemoteAudioVolume(
        _ volume: Int,
        for userID: String
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            try AgoraRtcPlatform.checkResult(
                platform.roomEngine.adjustUserPlaybackSignalVolumeEx(
                    try resolveUID(userID),
                    volume: volume,
                    connection: connection
                ),
                operation: "setRemoteAudioVolume"
            )
        }
    }

    /// Sets the remote decoded frame listener.
    ///
    /// - Parameters:
    ///   - listener: The frame callback; nil clears it.
    ///   - userID: The RTC user account.
    ///
    /// - Throws: An error if user mapping fails.
    func setRemoteVideoFrameListener(
        _ listener: RtcRemoteVideoFrameListener?,
        for userID: String
    )
        throws
    {
        try platform.lock.withLock {
            try requireJoined()
            let uid = try resolveUID(userID)
            // Joining does not depend on raw video access. Register only when frames are requested.
            if listener != nil {
                guard let videoSink, platform.setRemoteVideoSink(videoSink) else {
                    throw XmaxError(
                        code: .rtcError,
                        message: "Failed to register RTC video frame observer"
                    )
                }
            }
            callbackLock.withLock {
                if !callbackState.isClosed { callbackState.frameListeners[uid] = listener }
            }
        }
    }

    /// Sets a PCM listener for the resolved remote user without changing playback volume.
    ///
    /// - Parameters:
    ///   - listener: The owned audio handler, or `nil` to remove it.
    ///   - userID: The remote RTC user account.
    ///
    /// - Throws: An error if the room or remote account is unavailable.
    func setRemoteAudioFrameListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for userID: String
    ) throws {
        try platform.lock.withLock {
            try requireJoined()
            let uid = try resolveUID(userID)
            callbackLock.withLock {
                callbackState.audioListeners[uid] = callbackState.isClosed ? nil : listener
            }
        }
    }

    /// Enqueues room signaling.
    ///
    /// - Parameters:
    ///   - message: The complete JSON message.
    ///   - reportFailure: Whether asynchronous send failure is fatal. When `false`, failure is
    ///     logged and thrown to the waiting caller.
    ///   - key: The key replacing older, unsent messages with the same key.
    ///
    /// - Returns: The message's send task.
    ///
    /// - Throws: An error if the message is invalid or the queue is unavailable.
    @discardableResult
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool = true,
        replacingPendingMessage key: String? = nil
    ) throws -> Task<Void, any Error> {
        try platform.lock.withLock {
            try requireJoined()
            guard let sender else {
                throw XmaxError(
                    code: .rtcError,
                    message: "RTC signaling is unavailable"
                )
            }

            return try sender.enqueue(
                message,
                reportFailure: reportFailure,
                replacingPendingMessage: key
            )
        }
    }

    /// Drops coalescible messages that have not started sending.
    ///
    /// - Parameter key: The coalescing key, or `nil` for all coalescible messages.
    func discardPendingMessages(
        key: String?
    ) {
        platform.lock.withLock {
            sender?.discardPendingMessages(key: key)
        }
    }

    /// Waits for earlier queued signals to be submitted to RTC.
    ///
    /// - Throws: An error on send failure, room departure, or cancellation.
    func awaitPendingMessages() async throws {
        let sender = try platform.lock.withLock {
            try requireJoined()
            return sender
        }
        try await sender?.flush()
    }
}

private extension AgoraRtcRoom {

    /// Queues a native event for room lifecycle processing without blocking the callback.
    func enqueue(
        _ event: RtcRoomEventBridge.Event
    ) {
        eventQueue.async { [weak self] in self?.handle(event) }
    }

    /// Converts platform connection callbacks to room events and notifies listeners after unlocking.
    ///
    /// - Parameter event: The Agora connection callback event.
    func handle(
        _ event: RtcRoomEventBridge.Event
    ) {
        let events: [RtcRoomEvent] = platform.lock.withLock {
            guard !isClosed else { return [] }
            switch event {
            case .joined(let uid):
                guard !isJoined else { return [] }
                do {
                    try prepareJoinedRoom(uid: uid)
                    return [.joined]
                        + publications.compactMap { uid, published in
                            publicationEvent(
                                uid: uid,
                                published: published
                            )
                        }
                } catch {
                    return [.failure(XmaxError.from(error))]
                }
            case .account(
                let uid,
                let account
            ):
                accounts[uid] = account
                return publicationEvents(uid: uid)
            case .userJoined(let uid):
                resolveAccount(uid: uid)
                return publicationEvents(uid: uid)
            case .publication(
                let uid,
                let published
            ):
                publications[uid] = published
                resolveAccount(uid: uid)
                return publicationEvents(uid: uid)
            case .failure(let message):
                return [
                    .failure(
                        XmaxError(
                            code: .rtcError,
                            message: message
                        )
                    )
                ]
            case .quality(
                let up,
                let down
            ):
                return [
                    .quality(
                        uplink: up,
                        downlink: down
                    )
                ]
            case .localStats(
                let statistics,
                let adaptation,
                let width,
                let height,
                let frameRate
            ):
                RtcStatsLogger.logUplinkVideoStatistics(statistics)
                let events: [RtcRoomEvent] = [.uplinkVideoStatistics(statistics)]
                guard adaptation == 1 || adaptation == 2 else { return events }
                return events + [
                    .performance(
                        limited: adaptation == 2,
                        width: width,
                        height: height,
                        frameRate: frameRate
                    )
                ]
            case .remoteStats(
                let uid,
                let stats
            ):
                resolveAccount(uid: uid)
                guard let account = accounts[uid] else { return [] }
                let statistics = DownlinkVideoStatistics(
                    userID: account,
                    width: stats.width,
                    height: stats.height,
                    decodeFrameRate: stats.decodeFrameRate,
                    renderFrameRate: stats.renderFrameRate,
                    bitrateKbps: stats.bitrateKbps,
                    packetLossPercent: stats.packetLossPercent,
                    endToEndDelayMs: stats.endToEndDelayMs
                )
                RtcStatsLogger.logDownlinkVideoStatistics(statistics)
                return [.downlinkVideoStatistics(statistics)]
            }
        }

        // Notifies the lifecycle layer outside the platform lock to avoid reverse lock ordering.
        for event in events { emit(event) }
    }

    /// Creates an ordered signaling channel and finishes room initialization.
    ///
    /// - Parameter uid: The local user's numeric identifier.
    ///
    /// - Throws: An error if signaling data channel creation fails.
    func prepareJoinedRoom(
        uid: UInt
    ) throws {
        connection.localUid = uid
        let config = AgoraDataStreamConfig()
        config.ordered = true
        config.syncWithAudio = false
        try AgoraRtcPlatform.checkResult(
            platform.roomEngine.createDataStreamEx(
                &dataStreamID,
                config: config,
                connection: connection
            ),
            operation: "createDataStreamEx"
        )
        sender = RtcMessageQueue(
            send: { [weak self] data in
                guard let self else { throw CancellationError() }
                try platform.lock.withLock {
                    try requireJoined()
                    try AgoraRtcPlatform.checkResult(
                        platform.roomEngine.sendStreamMessageEx(
                            dataStreamID,
                            data: data,
                            connection: connection
                        ),
                        operation: "sendStreamMessageEx"
                    )
                }
            },
            onFailure: { [weak self] error in self?.emit(.failure(error)) }
        )
        isJoined = true
        callbackLock.withLock {
            if !callbackState.isClosed { callbackState.isJoined = true }
        }
    }

    /// Sends an event to a valid room listener.
    ///
    /// - Parameter event: The room event to report.
    func emit(
        _ event: RtcRoomEvent
    ) {
        let callback = callbackLock.withLock { callbackState.isClosed ? nil : callbackState.listener }
        callback?(event)
    }

    /// Gets current video publication events for known users.
    ///
    /// - Parameter uid: The remote user's numeric identifier.
    ///
    /// - Returns: Resolvable publication events; an empty array if state or account information is unavailable.
    func publicationEvents(
        uid: UInt
    ) -> [RtcRoomEvent] {
        guard let published = publications[uid],
            let event = publicationEvent(
                uid: uid,
                published: published
            )
        else { return [] }
        return [event]
    }

    /// Converts numeric user publication state to an account-based event.
    ///
    /// - Parameters:
    ///   - uid: The remote user's numeric identifier.
    ///   - published: Whether video is published.
    ///
    /// - Returns: The publication event if the account is available and the room joined; otherwise `nil`.
    func publicationEvent(
        uid: UInt,
        published: Bool
    ) -> RtcRoomEvent? {
        guard isJoined, let account = accounts[uid] else { return nil }
        return .publication(
            userID: account,
            published: published
        )
    }

    /// Retrieves uncached user accounts from the platform.
    ///
    /// - Parameter uid: The remote user's numeric identifier.
    func resolveAccount(
        uid: UInt
    ) {
        guard accounts[uid] == nil else { return }
        accounts[uid] =
            platform.roomEngine.getUserInfo(
                byUidEx: uid,
                connection: connection,
                withError: nil
            )?.userAccount
    }

    /// Looks up a user account's numeric identifier in the cache or platform.
    ///
    /// - Parameter account: The remote user account.
    ///
    /// - Returns: The numeric identifier for the account.
    ///
    /// - Throws: An error if account mapping is unavailable.
    func resolveUID(
        _ account: String
    ) throws -> UInt {
        if let uid = accounts.first(where: { $0.value == account })?.key { return uid }
        if let info = platform.roomEngine.getUserInfo(
            byUserAccountEx: account,
            connection: connection,
            withError: nil
        ) {
            accounts[info.uid] = account
            return info.uid
        }
        throw XmaxError(
            code: .rtcError,
            message: "RTC user account is not available: \(account)"
        )
    }

    /// Checks that the room is connected and not closed.
    ///
    /// - Throws: An error if the room is disconnected or closed.
    func requireJoined() throws {
        guard !isClosed, isJoined else {
            throw XmaxError(
                code: .rtcError,
                message: "RTC room is not joined"
            )
        }
    }

    /// Updates media options for the current connection.
    ///
    /// - Parameters:
    ///   - options: The publication or subscription configuration to apply.
    ///   - operation: The operation name used in error descriptions.
    ///
    /// - Throws: An error if the platform configuration update fails.
    func update(
        _ options: AgoraRtcChannelMediaOptions,
        operation: String
    ) throws {
        try AgoraRtcPlatform.checkResult(
            platform.roomEngine.updateChannelEx(
                with: options,
                connection: connection
            ),
            operation: operation
        )
    }
}

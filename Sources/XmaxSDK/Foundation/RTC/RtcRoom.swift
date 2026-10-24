//
//  RtcRoom.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Vendor-neutral events for one room connection.
enum RtcRoomEvent: Sendable {

    /// The RTC room connection succeeded.
    case joined

    /// A remote user's video publication changed.
    case publication(userID: String, published: Bool)

    /// The room connection or media transport failed.
    case failure(XmaxError)

    /// Uplink and downlink network quality changed.
    case quality(uplink: RtcQualityLevel, downlink: RtcQualityLevel)

    /// Uplink video statistics were updated.
    case uplinkVideoStatistics(UplinkVideoStatistics)

    /// Downlink video statistics were updated.
    case downlinkVideoStatistics(DownlinkVideoStatistics)

    /// Local encoding performance or format changed.
    case performance(limited: Bool, width: Int, height: Int, frameRate: Int)
}

/// Isolates third-party RTC room capabilities; each instance serves one connection.
protocol RtcRoom: AnyObject, Sendable {

    /// Sets the room event callback.
    ///
    /// - Parameter listener: The neutral event callback; nil clears it.
    func setEventListener(
        _ listener: (@Sendable (RtcRoomEvent) -> Void)?
    )

    /// Initiates joining; success is reported through the joined event.
    ///
    /// - Parameter configuration: The room, user account, and token.
    ///
    /// - Throws: An error if the join call fails immediately.
    func join(
        configuration: RoomJoinConfiguration
    ) throws

    /// Stops callbacks, clears signals and frame listeners, and leaves the room; repeated calls are harmless.
    func destroy()

    /// Updates local video publication state.
    ///
    /// - Parameter publish: Whether to publish the external video track.
    ///
    /// - Throws: An error if publication configuration fails.
    func publishLocalVideo(
        _ publish: Bool
    ) throws

    /// Updates local audio publication state.
    ///
    /// - Parameter publish: Whether to publish the current audio source.
    ///
    /// - Throws: An error if publication configuration fails.
    func publishLocalAudio(
        _ publish: Bool
    ) throws

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
    ) throws

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
    ) throws

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
    ) throws

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

    /// Enqueues a signal for the room.
    ///
    /// - Parameters:
    ///   - message: The complete JSON signal.
    ///   - reportFailure: Whether asynchronous send failure reports a room fault; false only logs and throws to the
    ///     awaiting caller.
    ///
    /// - Throws: An error if the signal is invalid or the queue unavailable.
    ///
    /// - Returns: The send task for this signal.
    @discardableResult
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool
    ) throws -> Task<Void, any Error>

    /// Waits for earlier queued signals to be submitted to RTC.
    ///
    /// - Throws: An error on send failure, room departure, or cancellation.
    func awaitPendingMessages() async throws
}

extension RtcRoom {

    /// Enqueues a room signal with asynchronous send failure reporting enabled.
    ///
    /// - Parameter message: The complete JSON signal.
    ///
    /// - Throws: An error if the signal is invalid or the send queue unavailable.
    func sendRoomMessage(
        _ message: String
    ) throws {
        try sendRoomMessage(
            message,
            reportFailure: true
        )
    }
}

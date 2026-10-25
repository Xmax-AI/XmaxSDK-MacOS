//
//  RtcManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines RTC engine, room, media transport, and remote frame output capabilities.
protocol RtcManaging: RtcCameraCapturing {

    /// Sets camera upstream mirroring, retaining the setting across encoder reconfiguration.
    ///
    /// - Parameter mirror: Whether to mirror the encoded camera stream.
    ///
    /// - Throws: An error if the engine is unavailable or rejects the setting.
    func configureLocalVideoMirror(
        _ mirror: Bool
    ) throws

    /// Acquires an exclusive RTC engine lease and completes initialization.
    ///
    /// - Throws: An error if lease waiting is cancelled or engine initialization fails.
    func initialize() async throws

    /// Destroys the RTC engine and releases resources.
    func destroy() async

    /// Applies upstream video encoding configuration.
    ///
    /// - Parameter configuration: Dimensions, frame rate, bitrate, and encoding preferences.
    ///
    /// - Throws: An error if the vendor engine rejects configuration.
    func configureVideoEncoding(
        _ configuration: VideoEncodingConfiguration
    ) throws

    /// Switches to microphone input and starts capture.
    ///
    /// - Throws: An error on audio source switching or capture failure.
    func startAudioCapture() throws

    /// Stops microphone capture.
    ///
    /// - Throws: An error if the vendor engine fails to stop capture.
    func stopAudioCapture() throws

    /// Enables external video input.
    ///
    /// - Throws: An error if video source configuration fails.
    func useExternalVideoSource() throws

    /// Enables external PCM input.
    ///
    /// - Throws: An error if external audio track creation fails.
    func startExternalAudioSource() throws

    /// Stops external PCM input and releases the audio track.
    ///
    /// - Throws: An error if audio track release fails.
    func stopExternalAudioSource() throws

    /// Pushes an external video frame.
    ///
    /// - Parameter frame: The SDK's neutral video frame.
    ///
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalVideoFrame(
        _ frame: VideoFrame
    ) throws

    /// Pushes an external audio frame.
    ///
    /// - Parameter frame: Timestamped 10 ms PCM data.
    ///
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalAudioFrame(
        _ frame: AudioFrame
    ) throws

    /// Joins an RTC room and waits for connection.
    ///
    /// - Parameter configuration: The room, user identifier, and token configuration.
    ///
    /// - Throws: An error on unavailable engine, join failure, timeout, or cancellation.
    func joinRoom(
        configuration: RoomJoinConfiguration
    ) async throws

    /// Leaves the current RTC room.
    func leaveRoom() async

    /// Publishes the local video stream.
    ///
    /// - Throws: An error if the room is unavailable or video publication fails.
    func publishLocalVideo() throws

    /// Stops local video publication.
    ///
    /// - Throws: An error if the room is unavailable or stopping video publication fails.
    func unpublishLocalVideo() throws

    /// Publishes the local audio stream.
    ///
    /// - Throws: An error if the room is unavailable or audio publication fails.
    func publishLocalAudio() throws

    /// Stops local audio publication.
    ///
    /// - Throws: An error if the room is unavailable or stopping audio publication fails.
    func unpublishLocalAudio() throws

    /// Sets video subscription state for a remote user.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - subscribe: Whether to subscribe to the video stream.
    ///
    /// - Throws: An error on unavailable room, user mapping failure, or subscription configuration failure.
    func subscribeRemoteVideo(
        userID: String,
        subscribe: Bool
    ) throws

    /// Sets audio subscription state for a remote user.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - subscribe: Whether to subscribe to the audio stream.
    ///
    /// - Throws: An error on unavailable room, user mapping failure, or subscription configuration failure.
    func subscribeRemoteAudio(
        userID: String,
        subscribe: Bool
    ) throws

    /// Sets audio playback volume for a remote user.
    ///
    /// - Parameters:
    ///   - volume: The playback volume from 0 to 100.
    ///   - userID: The remote RTC user identifier.
    ///
    /// - Throws: An error if the room is unavailable or volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Int,
        for userID: String
    ) throws

    /// Sets the decoded frame listener for a remote stream.
    ///
    /// - Parameters:
    ///   - listener: The decoded frame callback; `nil` clears it.
    ///   - stream: The remote stream to observe.
    ///
    /// - Throws: An error if the room is unavailable or frame listener configuration fails.
    func setRemoteVideoFrameListener(
        _ listener: RtcRemoteVideoFrameListener?,
        for stream: RemoteStream
    ) throws

    /// Sends a message to the current RTC room.
    ///
    /// - Parameters:
    ///   - message: The complete JSON signal.
    ///   - reportFailure: Whether asynchronous send failures report room faults.
    ///   - key: The key replacing older, unsent messages with the same key.
    ///
    /// - Returns: The signal send task for awaiting this message's result independently.
    ///
    /// - Throws: An error if enqueueing fails.
    @discardableResult
    func sendRoomMessage(
        _ message: String,
        reportFailure: Bool,
        replacingPendingMessage key: String?
    ) throws -> Task<Void, any Error>

    /// Drops coalescible messages that have not started sending.
    ///
    /// - Parameter key: The coalescing key, or `nil` for all coalescible messages.
    func discardPendingMessages(
        key: String?
    )

    /// Waits for queued room signals to finish sending.
    ///
    /// - Throws: An error on unavailable room, send failure, or cancelled waiting.
    func awaitPendingMessages() async throws

    /// Sets the RTC connection and media event listener.
    ///
    /// - Parameter listener: The event listener; `nil` clears it.
    func setEventListener(
        _ listener: (any RtcEventListener)?
    )

    /// Sets the RTC network and media quality listener.
    ///
    /// - Parameter listener: The quality listener; `nil` clears it.
    func setQualityListener(
        _ listener: (any RtcQualityListener)?
    )

    /// Sets an owned PCM callback for the current remote user without changing playback.
    ///
    /// - Parameters:
    ///   - listener: The PCM callback; nil removes it.
    ///   - stream: The current room and result user.
    ///
    /// - Throws: An error if the room or remote user is unavailable.
    func setRemoteAudioFrameListener(
        _ listener: RtcRemoteAudioFrameListener?,
        for stream: RemoteStream
    ) throws

}

extension RtcManaging {

    /// Enqueues a room signal with asynchronous send failure reporting enabled.
    ///
    /// - Parameter message: The complete JSON signal.
    ///
    /// - Throws: An error if the signal cannot be enqueued.
    func sendRoomMessage(
        _ message: String
    ) throws {
        try sendRoomMessage(
            message,
            reportFailure: true,
            replacingPendingMessage: nil
        )
    }
}

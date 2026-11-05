//
//  RtcPlatform.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Receives remote video frames in SDK-owned pixel buffers.
typealias RtcRemoteVideoFrameListener = @Sendable (RealtimeVideoFrame) -> Void

/// Receives normalized native input metadata; application delivery belongs to the microphone monitor.
typealias RtcMicrophoneLevelListener = @Sendable (Float?) -> Void

/// The local microphone metadata supplied by native engine or channel delegates.
enum RtcMicrophoneEvent: Sendable {

    /// The normalized strength of the physical local input.
    case level(Float)

    /// Whether native capture remains able to supply usable readings.
    case availability(Bool)
}

/// Isolates third-party RTC capabilities from connection waits, timeouts, and lease management.
protocol RtcPlatform: AnyObject, RtcCameraCapturing {

    /// Sets camera upstream mirroring, retaining the setting across encoder reconfiguration.
    ///
    /// - Parameter mirror: Whether to mirror the encoded camera stream.
    ///
    /// - Throws: An error if the vendor encoder rejects the setting.
    func configureLocalVideoMirror(
        _ mirror: Bool
    ) throws

    /// Applies upstream video encoding configuration.
    ///
    /// - Parameter configuration: Dimensions, frame rate, bitrate, and encoding preferences.
    ///
    /// - Throws: An error if the vendor engine rejects configuration.
    func configureVideoEncoding(
        _ configuration: VideoEncodingConfiguration
    ) throws

    /// Enables external video input.
    ///
    /// - Throws: An error if video source configuration fails.
    func useExternalVideoSource() throws

    /// Switches to microphone input and starts capture.
    ///
    /// - Parameter deviceID: The Core Audio input UID; nil follows the system default input.
    ///
    /// - Throws: An error on audio source switching or capture failure.
    func startAudioCapture(
        deviceID: String?
    ) throws

    /// Selects an input UID, or follows the system default when nil, without changing capture state.
    func setMicrophoneDevice(
        _ deviceID: String?
    ) throws

    /// Configures best-effort local input observation without enabling audio capture.
    func setMicrophoneLevelListener(
        _ listener: RtcMicrophoneLevelListener?
    )

    /// Stops microphone capture.
    ///
    /// - Throws: An error if the vendor engine fails to stop capture.
    func stopAudioCapture() throws

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

    /// Creates an independent room adapter without initiating connection.
    ///
    /// - Parameter roomID: The server-assigned RTC room identifier.
    ///
    /// - Returns: The room before joining.
    ///
    /// - Throws: An error if an unreleased room already exists.
    func createRoom(
        roomID: String
    ) throws -> any RtcRoom
}

//
//  RtcPlatform.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Receives remote video frames in SDK-owned pixel buffers.
typealias RtcRemoteVideoFrameListener = @Sendable (RealtimeVideoFrame) -> Void

/// Isolates third-party RTC capabilities from connection waits, timeouts, and lease management.
protocol RtcPlatform: AnyObject, RtcCameraCapturing {

    /// Applies upstream video encoding configuration.
    ///
    /// - Parameter configuration: Dimensions, frame rate, bitrate, and encoding preferences.
    /// - Throws: An error if the vendor engine rejects configuration.
    func configureVideoEncoding(_ configuration: VideoEncodingConfiguration) throws

    /// Enables external video input.
    ///
    /// - Throws: An error if video source configuration fails.
    func useExternalVideoSource() throws

    /// Switches to microphone input and starts capture.
    ///
    /// - Throws: An error on audio source switching or capture failure.
    func startAudioCapture() throws

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
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalVideoFrame(_ frame: VideoFrame) throws

    /// Pushes an external audio frame.
    ///
    /// - Parameter frame: Timestamped 10 ms PCM data.
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalAudioFrame(_ frame: AudioFrame) throws

    /// Creates an independent room adapter without initiating connection.
    ///
    /// - Parameter roomID: The server-assigned RTC room identifier.
    /// - Returns: The room before joining.
    /// - Throws: An error if an unreleased room already exists.
    func createRoom(roomID: String) throws -> any RtcRoom
}

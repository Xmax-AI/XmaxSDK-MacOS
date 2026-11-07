//
//  CameraControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Reports camera preview readiness with a validity check for asynchronous handling.
typealias CameraPreviewReadyHandler =
    @MainActor @Sendable (
        _ isCurrent: @escaping @Sendable () -> Bool
    ) -> Void

/// Defines local camera stream, microphone capture, and preview resource management.
protocol CameraControlling: Sendable {

    /// The local camera video track, or nil before creation or after stopping.
    var currentTrack: RealtimeVideoTrack? { get }

    /// Whether the current camera stream is configured to use the microphone.
    var useMicrophone: Bool { get }

    /// Lists currently available camera devices.
    ///
    /// - Returns: The currently selectable system video devices.
    func listCameraDevices() -> [CameraDevice]

    /// Reports the first valid capture frame and a bound preview, including hidden views.
    ///
    /// - Parameter handler: The readiness callback; an empty value clears it.
    func setPreviewReadyHandler(
        _ handler: CameraPreviewReadyHandler?
    )

    /// Creates and starts a local camera stream.
    ///
    /// - Parameters:
    ///   - videoFormat: The requested dimensions, frame rate, and encoding configuration; dimensions follow model
    ///     rules.
    ///   - deviceID: The initial device identifier; an empty value uses the system default camera.
    ///   - mirror: Whether to mirror camera preview and upstream encoding.
    ///   - useMicrophone: Whether to request microphone permission and allow capture when realtime connects.
    ///
    /// - Returns: The media stream containing the local camera video track.
    ///
    /// - Throws: An error on an existing camera stream, invalid format, insufficient permissions, or capture startup
    ///   failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        mirror: Bool,
        useMicrophone: Bool
    ) async throws -> RealtimeMediaStream

    /// Prepares RTC audio input and starts physical capture if the microphone is enabled.
    ///
    /// - Throws: An error on RTC audio source configuration or microphone capture startup failure.
    func startMicrophoneCapture() throws

    /// Stops microphone capture while retaining configuration for the next connection.
    ///
    /// - Throws: An error if stopping RTC microphone capture fails.
    func stopMicrophoneCapture() throws

    /// Selects a microphone by its system UID.
    func switchMicrophone(to deviceID: String?) throws

    /// Observes the selected microphone's input level.
    @MainActor func setMicrophoneLevelListener(_ listener: RealtimeMicrophoneLevelListener?)

    /// Updates microphone intent, checking permission before enabling and capture validity after suspension.
    func setMicrophoneEnabled(
        _ enabled: Bool,
        capture: Bool,
        ensureCurrent: @escaping @Sendable () throws -> Void
    ) async throws

    /// Stops camera and microphone capture and releases the track and local preview resources.
    func stopLocalCameraStream() async

    /// Updates camera dimensions, frame rate, and encoding settings without replacing its track.
    func updateVideoFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async throws

    /// Switches to the specified camera device while retaining the current video track.
    ///
    /// - Returns: The media stream containing the updated camera track.
    ///
    /// - Throws: An error if no camera stream is active or device switching fails.
    func switchCamera(
        to deviceID: String
    ) async throws -> RealtimeMediaStream

}

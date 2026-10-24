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

    /// Lists currently available camera devices.
    ///
    /// - Returns: The currently selectable system video devices.
    func listCameraDevices() -> [CameraDevice]

    /// The local camera video track, or nil before creation or after stopping.
    var currentTrack: RealtimeVideoTrack? { get }

    /// Whether the current camera stream is configured to use the microphone.
    var useMicrophone: Bool { get }

    /// Reports ready capture and a bound preview. Native capture uses engine state events, including for hidden views.
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
    ///   - useMicrophone: Whether to request microphone permission and allow capture when realtime connects.
    ///
    /// - Returns: The media stream containing the local camera video track.
    ///
    /// - Throws: An error on an existing camera stream, invalid format, insufficient permissions, or capture startup
    ///   failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        useMicrophone: Bool
    ) async throws -> RealtimeMediaStream

    /// Starts audio capture for a microphone-enabled camera stream without local playback.
    ///
    /// - Throws: An error on RTC audio source configuration or microphone capture startup failure.
    func startMicrophoneCapture() throws

    /// Stops microphone capture while retaining configuration for the next connection.
    ///
    /// - Throws: An error if stopping RTC microphone capture fails.
    func stopMicrophoneCapture() throws

    /// Stops camera and microphone capture and releases the track and local preview resources.
    func stopLocalCameraStream() async

    /// Switches to the specified camera device while retaining the current video track.
    ///
    /// - Returns: The media stream containing the updated camera track.
    ///
    /// - Throws: An error if no camera stream is active or device switching fails.
    func switchCamera(
        to deviceID: String
    ) async throws -> RealtimeMediaStream

}

//
//  MediaControlling.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines unified media capabilities exposed to Core.
protocol MediaControlling: Actor, InteractionControlling {

    /// Acquires the shared RTC engine before camera and connection work are forked.
    func initializeRTC() async throws

    /// Lists available camera devices without starting capture.
    ///
    /// - Returns: Devices with their identifiers, names, and default status.
    func listCameraDevices() -> [CameraDevice]

    /// The active local video track.
    var currentTrack: RealtimeVideoTrack? { get }

    /// The current local video format.
    var currentVideoFormat: RealtimeVideoFormat? { get }

    /// Whether the current local source is caller-owned external video.
    var isExternalVideo: Bool { get }

    /// Whether to preserve media aspect ratio with a separate generation canvas; false for cameras.
    var usesContainPadding: Bool { get }

    /// Whether the current source includes SDK-managed local audio.
    var hasAudio: Bool { get }

    /// Sets a one-time internal readiness handler for the current camera stream.
    ///
    /// - Parameter handler: Called after capture is ready and preview is bound; an empty value clears it.
    func setCameraPreviewReadyHandler(_ handler: CameraPreviewReadyHandler?)

    /// Creates and retains a local camera stream, starting capture and local preview.
    ///
    /// - Parameters:
    ///   - videoFormat: The target camera capture video format.
    ///   - deviceID: The initial device identifier; an empty value uses the system default camera.
    ///   - useMicrophone: Whether to use the microphone; permission is checked at creation and capture starts on connection.
    /// - Returns: The media stream containing the local camera video track.
    /// - Throws: An error on camera permission, RTC initialization, or capture startup failure;
    ///   also fails if a media source is already active.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        useMicrophone: Bool,
        retainRTCOnFailure: Bool
    ) async throws -> RealtimeMediaStream

    /// Binds caller-owned video input without acquiring camera permissions or capture resources.
    func createExternalVideoStream(
        source: any RealtimeExternalVideoSource,
        videoFormat: RealtimeVideoFormat?
    ) async throws -> RealtimeMediaStream

    /// Unbinds external video input and releases its SDK resources.
    func stopExternalVideoStream() async

    /// Starts internal audio capture for a microphone-enabled camera stream; other sources are unaffected.
    ///
    /// - Throws: An error on cancellation or RTC audio capture startup failure.
    func startMicrophoneCapture() throws

    /// Stops microphone capture while retaining camera preview and microphone configuration.
    ///
    /// - Throws: An error if stopping RTC audio capture fails.
    func stopMicrophoneCapture() throws

    /// Cancels pending camera creation and releases SDK-owned capture before remote cleanup.
    /// RTC resources remain alive until the connection has been disconnected.
    func stopLocalCapture() async

    /// Stops and releases the local camera stream, preview binding, and RTC resources;
    /// does nothing if the current source is not a camera.
    func stopLocalCameraStream() async

    /// Switches to the specified camera device while retaining the current video track.
    ///
    /// - Returns: The local media stream with the updated camera position.
    /// - Throws: An error if the current source is not a camera, another media operation exists, or switching fails.
    func switchCamera(to deviceID: String) async throws -> RealtimeMediaStream

    /// Stops and releases the local media stream, preview binding, and RTC engine;
    /// does nothing without an active source.
    func stopLocalStream() async

    /// Checks whether the active media source owns the specified stream.
    ///
    /// - Parameter stream: The media stream whose ownership is being validated.
    /// - Returns: `true` if the active source owns the stream's video track;
    ///   otherwise returns `false`.
    func owns(_ stream: RealtimeMediaStream) -> Bool
}

//
//  XmaxRealtimeManaging.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines public realtime media and generation controls.
public protocol XmaxRealtimeManaging: Sendable {

    /// Lists available camera devices without starting capture.
    ///
    /// - Returns: Devices with their identifiers, names, and default status.
    func listCameraDevices() async -> [CameraDevice]

    /// Realtime capability configuration.
    var options: RealtimeConfiguration { get }

    /// The current realtime connection and generation state.
    var currentState: RealtimeState { get async }

    /// The effective remote video interpolation state.
    var isFrameInterpolationEnabled: Bool { get async }


    /// The remote generated audio playback volume in `0...1`.
    /// Starts at 0 after camera stream creation; enable result audio when needed.
    var remoteAudioVolume: Float { get async }

    /// Sets the realtime state listener.
    ///
    /// - Parameter listener: The realtime state callback; `nil` clears the listener.
    func setStateListener(
        _ listener: RealtimeStateListener?
    ) async

    /// Sets the startup timing listener for camera startup, four generation stages, and total timing.
    ///
    /// - Parameter listener: The main-thread snapshot callback; `nil` clears the listener.
    func setLaunchTimingListener(_ listener: RealtimeLaunchTimingListener?) async

    /// Sets the final remote video frame listener.
    ///
    /// Receives frames after optional interpolation, immediately before display. The SDK invokes the callback
    /// on an internal serial queue without blocking the main thread. Forward frames promptly and avoid
    /// expensive encoding in the callback. Pass `nil` to clear the listener.
    ///
    /// - Parameter listener: The final remote video frame callback.
    func setRemoteVideoFrameListener(
        _ listener: RealtimeVideoFrameListener?
    ) async

    /// Sets the upstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil before publication or after disconnect. Pass nil to clear it.
    func setUplinkVideoStatisticsListener(_ listener: UplinkVideoStatisticsListener?) async

    /// Sets the downstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil when the result stream is cleared. Pass nil to clear it.
    func setDownlinkVideoStatisticsListener(_ listener: DownlinkVideoStatisticsListener?) async

    /// Sets the network quality listener.
    ///
    /// - Parameter listener: The upstream and downstream network quality callback; `nil` clears the listener.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    ) async

    /// Sets the device performance alarm listener.
    ///
    /// - Parameter listener: The device performance alarm callback; `nil` clears the listener.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    ) async

    /// Sets the playback volume for remote generated audio.
    ///
    /// Stores the setting before connection or subscription and applies it before remote audio playback starts.
    /// Call after creating the local stream to override the initial volume.
    ///
    /// - Parameter volume: The remote playback volume in `0...1`.
    /// - Throws: An error if the volume is out of range or RTC volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Float
    ) async throws

    /// Enables or disables interpolation of generated remote video.
    ///
    /// Overrides the initial setting. During generation, enabling requests proportionally smaller return dimensions;
    /// disabling restores dimensions for the current network tier, without reconnecting or restarting generation.
    /// Original frames remain visible during the dimension change.
    ///
    /// - Parameter enabled: Whether to enable remote video interpolation.
    /// - Throws: An error on conflicting operations, unsupported devices or dimensions, or signal delivery failure.
    func setFrameInterpolationEnabled(
        _ enabled: Bool
    ) async throws

    /// Creates a local camera stream and starts preview.
    ///
    /// Bind the returned track to a preview view; media becomes `ready` after native capture starts and the view is bound.
    ///
    /// - Parameters:
    ///   - videoFormat: The camera capture video format.
    ///   - deviceID: The initial device identifier; an empty value uses the system default camera.
    ///   - useMicrophone: Whether to use the microphone; requests permission at creation, starts capture on connection, and stops on disconnect.
    /// - Returns: The media stream containing the local camera video track.
    /// - Throws: An error on invalid configuration, denied permissions, conflicting operations, or capture startup failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        useMicrophone: Bool
    ) async throws -> RealtimeMediaStream

    /// Acquires Agora, then prepares capture and the cloud connection concurrently before starting generation.
    /// The local-stream callback runs on the main actor as soon as capture is usable; bind it to a preview if desired.
    /// Preview attachment is not a prerequisite for joining or publishing. Failure or cancellation releases both branches.
    /// Camera and RTC stage durations overlap and must not be summed to obtain total startup time.
    func startCameraGeneration(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        useMicrophone: Bool,
        context: RealtimeContext,
        faceRestoration: Bool,
        localStreamListener: @escaping @MainActor @Sendable (RealtimeMediaStream) -> Void
    ) async throws -> RealtimeMediaStream

    /// Stops the local camera stream and updates media readiness.
    ///
    /// - Throws: An error if realtime is still connected, a conflicting operation exists, or this operation is cancelled.
    func stopLocalCameraStream() async throws

    /// Binds a caller-owned video source and returns its local stream.
    ///
    /// The source owns capture, permissions, conversion, and optional preview. The SDK
    /// validates the final format and passes it to `source.start(sink:)`. Binding completion
    /// enters `ready` without waiting for preview or a frame. Supply frames as soon as the
    /// sink requests them, including while generation is starting.
    ///
    /// - Parameters:
    ///   - source: The caller-owned video source.
    ///   - videoFormat: The desired input format; nil uses source dimensions and the model frame rate.
    /// - Returns: The local stream used for connection, generation, and optional SDK-hosted preview.
    /// - Throws: An error on conflicting media, invalid format, failed binding, or cancellation.
    func createExternalVideoStream(
        source: any RealtimeExternalVideoSource,
        videoFormat: RealtimeVideoFormat?
    ) async throws -> RealtimeMediaStream

    /// Unbinds external input after disconnection; caller-owned capture resources remain caller-managed.
    ///
    /// - Throws: An error if still connected, another operation conflicts, or the operation is cancelled.
    func stopExternalVideoStream() async throws

    /// Switches the active camera device.
    ///
    /// During generation, the SDK stops generation, switches cameras, and resumes with cached conditions.
    /// The RTC connection is retained. Camera switching is unavailable while connection or generation starts.
    ///
    /// - Returns: The local stream retaining the original video track with its camera position updated.
    /// - Throws: An error if no camera stream exists, realtime startup is in progress, or camera switching or generation recovery
    ///   fails.
    func switchCamera(to deviceID: String) async throws -> RealtimeMediaStream

    /// Establishes a realtime connection with the local stream created by this manager.
    ///
    /// - Parameter localStream: The local media stream created and owned by this manager.
    /// - Returns: The connected remote media stream, which can be bound to a result preview view.
    /// - Throws: An error on invalid local stream, existing connection, conflicting operation, cancellation, or connection failure.
    func connect(
        localStream: RealtimeMediaStream
    ) async throws -> RealtimeMediaStream

    /// Disconnects realtime while retaining the local media preview.
    func disconnect() async

    /// Disconnects realtime for a business reason while retaining usable local media.
    ///
    /// - Parameter reason: The disconnect reason, such as a display orientation change.
    func disconnect(reason: RealtimeReason) async

    /// Closes the realtime lifecycle and releases the connection, local media, and RTC engine.
    ///
    /// Concurrent close calls await the same cleanup task; local streams can be created again after close completes.
    func close() async

    /// Starts generation, or updates current conditions if generation is already active.
    ///
    /// A newer generation request replaces an unfinished one after its cleanup completes.
    /// The replaced request ends with cancellation. Disconnect and close cancel pending requests.
    ///
    /// - Parameters:
    ///   - context: The generation conditions; required initially. Later calls may pass `nil` to reuse cached conditions.
    ///   - faceRestoration: Whether to restore the original face; each call sends this setting.
    /// - Throws: An error if conditions are invalid or generation startup or update fails.
    func startGeneration(
        context: RealtimeContext?,
        faceRestoration: Bool
    ) async throws

    /// Connects using the current local stream when needed and starts generation.
    ///
    /// Reuses an existing connection and the same request-replacement behavior as the context-only overload.
    /// The returned remote stream can display results in the unified video view.
    ///
    /// - Parameters:
    ///   - localStream: The local media stream created and owned by this manager.
    ///   - context: The generation conditions; required for initial generation.
    ///   - faceRestoration: Whether to restore the original face; each call sends this setting.
    /// - Returns: The remote media stream for the current RTC connection.
    /// - Throws: An error on invalid local stream, connection failure, or generation startup failure.
    func startGeneration(
        localStream: RealtimeMediaStream,
        context: RealtimeContext?,
        faceRestoration: Bool
    ) async throws -> RealtimeMediaStream
}

//
//  XmaxRealtimeManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines public realtime media and generation controls.
public protocol XmaxRealtimeManaging: Sendable {

    /// The initial realtime configuration.
    var configuration: RealtimeConfiguration { get }

    /// The current realtime connection and generation state.
    var currentState: RealtimeState { get async }

    /// The camera's resolved media format, or `nil` without a camera stream. Uplink quality changes
    /// do not affect it.
    var currentCameraVideoFormat: RealtimeVideoFormat? {
        get async
    }

    /// The preset matching the camera dimensions, or `nil` if no camera or matching preset exists.
    var currentCameraPreset: RealtimeCameraPreset? {
        get async
    }

    /// The applied uplink level, or `nil` before connection completes or after disconnection
    /// begins.
    var uplinkQualityLevel: RealtimeQualityLevel? {
        get async
    }

    /// The submitted downlink level, or `nil` before connection completes or after disconnection
    /// begins.
    ///
    /// The server may begin returning the new dimensions after this value changes.
    var downlinkQualityLevel: RealtimeQualityLevel? {
        get async
    }

    /// The effective remote video interpolation state.
    var isFrameInterpolationEnabled: Bool { get async }

    /// The remote generated audio playback volume in `0...1`.
    /// Starts at 0 after camera stream creation; enable result audio when needed.
    var remoteAudioVolume: Float { get async }

    /// Whether the local camera stream is configured to capture microphone audio while connected.
    var isMicrophoneEnabled: Bool { get async }

    /// Lists available camera devices without starting capture.
    ///
    /// - Returns: Devices with their identifiers, names, and default status.
    func listCameraDevices() async -> [CameraDevice]

    /// Lists microphone inputs without starting capture or requesting microphone permission.
    ///
    /// - Returns: Physical and virtual inputs with stable UIDs, names, and default status.
    func listMicrophoneDevices() async -> [MicrophoneDevice]

    /// Observes physical microphone input strength without starting capture or requesting permission.
    ///
    /// Registration immediately replays the latest reading on the main actor. Native samples arrive
    /// approximately every 200 ms while the microphone is captured and native readings are available.
    /// Pending samples are coalesced. `nil` clears stale input on stop, disconnect, input replacement,
    /// or native capture failure; a measured zero means silence. External and remote audio are excluded.
    /// Observation survives capture restarts until replaced or explicitly removed.
    ///
    /// - Parameter listener: The input-strength receiver. Pass nil to remove it and invalidate queued delivery;
    ///   after removal returns, no queued callback is delivered to the previous listener.
    func setMicrophoneLevelListener(
        _ listener: RealtimeMicrophoneLevelListener?
    ) async

    /// Updates a ready, disconnected camera stream while preserving its track and view bindings.
    ///
    /// - Parameter videoFormat: The new capture dimensions, frame rate, and encoding settings.
    ///   Dimensions must match a supported model format.
    ///
    /// - Throws: An error if the state or format is invalid, another operation is active, or device
    ///   configuration fails.
    func updateCameraFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async throws

    /// Updates camera dimensions while preserving the current frame rate, bitrate, and encoding
    /// preference.
    ///
    /// - Parameter preset: A resolution preset supported by the model.
    ///
    /// - Throws: An error if the state or preset is invalid, another operation is active, or device
    ///   configuration fails.
    func updateCameraFormat(
        _ preset: RealtimeCameraPreset
    ) async throws

    /// Changes the uplink encoding level during generation without changing capture or generation
    /// dimensions.
    ///
    /// Automatic adaptation may subsequently change the level; a manual selection does not lock it.
    ///
    /// - Parameter level: The requested uplink quality level.
    ///
    /// - Throws: An error if generation is inactive, an operation conflicts or is cancelled, or
    ///   encoder configuration fails.
    func setUplinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws

    /// Changes the downlink level during generation while retaining frame interpolation limits.
    ///
    /// Automatic adaptation may subsequently change the level; a manual selection does not lock it.
    ///
    /// - Parameter level: The requested downlink quality level.
    ///
    /// - Throws: An error if generation is inactive, an operation conflicts or is cancelled, or
    ///   signaling or rendering configuration fails.
    func setDownlinkQualityLevel(
        _ level: RealtimeQualityLevel
    ) async throws

    /// Sets beauty on generated result frames shared by preview and `setRemoteMediaFrameListener`.
    ///
    /// Disabled by default. Pass options to enable or nil to disable. SDR output color preparation
    /// is shared by both settings, so changing beauty does not change the result's color interpretation.
    /// Can be configured before connection or changed during generation. Options survive result
    /// replacement and reconnection; `close()` restores disabled beauty.
    /// Runtime failures automatically disable beauty, retain generation, and notify the independent listener.
    ///
    /// - Parameter options: Finite strengths in `0...1`, or nil to disable beauty processing.
    ///
    /// - Throws: An error for invalid strengths, unavailable processing, configuration failure, or cancellation.
    func setRemoteVideoBeauty(
        _ options: RealtimeVideoBeautyOptions?
    ) async throws

    /// Sets the recoverable beauty error callback, delivered on the main actor after beauty is disabled.
    ///
    /// Configuration errors are thrown by `setRemoteVideoBeauty`; this listener reports later frame failures.
    /// It does not report terminal generation errors and is cleared on `close()`.
    ///
    /// - Parameter listener: The callback, or nil to remove it.
    func setRemoteVideoBeautyErrorListener(
        _ listener: RealtimeVideoBeautyErrorListener?
    ) async

    /// Sets the realtime state listener.
    ///
    /// - Parameter listener: The realtime state callback; `nil` clears the listener.
    func setStateListener(
        _ listener: RealtimeStateListener?
    ) async

    /// Sets the startup timing listener for the four generation stages and total timing.
    ///
    /// - Parameter listener: The main-thread snapshot callback; `nil` clears the listener.
    func setLaunchTimingListener(
        _ listener: RealtimeLaunchTimingListener?
    ) async

    /// Observes selected tracks of the SDK-owned local camera stream.
    ///
    /// Camera frames are sized for the local stream, before RTC encoding and view mirroring.
    /// Microphone PCM arrives while the configured input is capturing during connection.
    /// Both tracks share the host capture clock. Registering does not start capture.
    ///
    /// Callbacks run on a dedicated serial background queue in delivery order. The queue
    /// is bounded and marks dropped packets as discontinuities. Keep the callback short.
    /// A callback already running may finish after removal. `close()` clears the listener.
    ///
    /// - Parameters:
    ///   - tracks: The tracks to deliver from the local camera stream.
    ///   - listener: The callback, or `nil` to remove it and invalidate queued delivery.
    func setLocalMediaFrameListener(
        tracks: Set<RealtimeMediaTrack>,
        _ listener: RealtimeMediaFrameListener?
    ) async

    /// Sets one listener for the result user's PCM and processed remote video.
    ///
    /// Audio is copied before remote-user mixing; video includes optional interpolation and beauty. Both use
    /// the receiver rendering timeline. Audio time advances by sample count between explicit
    /// discontinuities. Registration does not change playback volume or audio subscriptions.
    ///
    /// Call before generation or replace the listener while connected. Callbacks run on a dedicated
    /// serial background queue, in delivery order rather than cross-track PTS order. Forward packets
    /// promptly: pending output is bounded to 256 packets and 32 MiB, and discarded packets mark the
    /// next event of that track as discontinuous. A callback already running may finish after removal.
    ///
    /// - Parameter listener: The remote output handler, or `nil` to remove it and queued output.
    ///
    /// - Throws: An error if observation of an already-bound remote user cannot be configured.
    func setRemoteMediaFrameListener(
        _ listener: RealtimeMediaFrameListener?
    ) async throws

    /// Sets the upstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil before publication or after disconnect. Pass nil to
    ///   clear it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    ) async

    /// Sets the downstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil when the result stream is cleared. Pass nil to
    ///   clear it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    ) async

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
    ///
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
    ///
    /// - Throws: An error on conflicting operations, unsupported devices or dimensions, or signal delivery failure.
    func setFrameInterpolationEnabled(
        _ enabled: Bool
    ) async throws

    /// Creates a local camera stream and starts preview.
    ///
    /// Bind the returned track to a preview view; media becomes `ready` after native capture starts and the view is
    /// bound.
    ///
    /// - Parameters:
    ///   - videoFormat: The camera capture video format.
    ///   - camera: The initial camera selection.
    ///   - microphone: The initial microphone selection. Enabled inputs request permission at creation,
    ///     start capture on connection, and stop on disconnect. Use `switchMicrophone(to:)`
    ///     and `setMicrophoneEnabled(_:)` for runtime changes.
    ///   - mirror: Whether to mirror both native local preview and the encoded camera stream.
    ///     Generated output and frame callbacks retain the direction returned by the server.
    ///
    /// - Returns: The media stream containing the local camera video track.
    ///
    /// - Throws: An error on invalid configuration, denied permissions, conflicting operations, input selection,
    ///   or capture startup failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        camera: RealtimeCamera,
        microphone: RealtimeMicrophone,
        mirror: Bool
    ) async throws -> RealtimeMediaStream

    /// Stops the local camera stream and updates media readiness.
    ///
    /// - Throws: An error if realtime is still connected, a conflicting operation exists, or this operation is
    ///   cancelled.
    func stopLocalCameraStream() async throws

    /// Binds an external video source with optional audio for realtime generation.
    ///
    /// The source frame rate and encoding settings are retained. Media dimensions are limited by
    /// the model's maximum area and aligned to multiples of 4. Camera resolution buckets do not
    /// apply. Submit frames at `source.videoFormat` dimensions; XmaxSDK resizes them automatically
    /// and exposes the resolved format through `sink.videoFormat`.
    ///
    /// Sources declaring `hasAudio` can submit PCM for RTC upload. XmaxSDK doesn't request
    /// microphone permission or play submitted audio locally.
    ///
    /// The state becomes `ready` when binding completes, without waiting for a frame. Disconnection
    /// preserves frame delivery and preview. `stopExternalVideoStream()` and `close()` unbind the
    /// source without taking ownership of its capture resources.
    ///
    /// - Parameters:
    ///   - source: The video source implemented and owned by your app.
    ///   - videoFormat: Optional processing format; nil retains the source frame rate and encoding settings.
    ///
    /// - Returns: A local stream for an `XmaxRealtimeVideoView` or realtime generation.
    ///
    /// - Throws: An error if the format is invalid, a stream already exists, an operation
    ///   conflicts, or source binding fails.
    func createExternalVideoStream(
        source: any RealtimeExternalVideoSource,
        videoFormat: RealtimeVideoFormat?
    ) async throws -> RealtimeMediaStream

    /// Stops external frame delivery and clears the SDK preview without taking ownership of capture
    /// resources.
    ///
    /// - Throws: An error if realtime is still connected, another operation conflicts, or the
    ///   operation is cancelled.
    func stopExternalVideoStream() async throws

    /// Switches the active camera device.
    ///
    /// During generation, the SDK stops generation, switches cameras, and resumes with cached conditions.
    /// The RTC connection is retained. Camera switching is unavailable while connection or generation starts.
    ///
    /// - Returns: The local stream retaining the original video track with its camera position updated.
    ///
    /// - Throws: An error if no camera stream exists, realtime startup is in progress, or camera switching or
    ///   generation recovery
    ///   fails.
    func switchCamera(
        to deviceID: String
    ) async throws -> RealtimeMediaStream

    /// Switches microphone input without restarting generation or the RTC connection.
    ///
    /// Requires a local camera stream. While microphone capture is disabled, only the input selection changes.
    ///
    /// - Parameter deviceID: The Core Audio input UID; nil follows the system default input.
    /// - Throws: An error if media is unavailable, another operation is active, or device selection fails.
    func switchMicrophone(
        to deviceID: String?
    ) async throws

    /// Enables or disables microphone capture and publication while retaining video generation.
    ///
    /// Before connection, updates microphone intent without starting capture. Enabling requests permission.
    /// Available for camera streams; caller-owned external audio is unaffected.
    /// Disabling still stops capture when unpublication fails, and reports that publication error.
    ///
    /// - Parameter enabled: Whether to capture and publish the selected microphone while connected.
    /// - Throws: An error on invalid state, denied permission, capture failure, or publication failure.
    func setMicrophoneEnabled(
        _ enabled: Bool
    ) async throws

    /// Establishes a realtime connection with the local stream created by this manager.
    ///
    /// - Parameter localStream: The local media stream created and owned by this manager.
    ///
    /// - Returns: The connected remote media stream, which can be bound to a result preview view.
    ///
    /// - Throws: An error on invalid local stream, existing connection, conflicting operation, cancellation, or
    ///   connection failure.
    func connect(
        localStream: RealtimeMediaStream
    ) async throws -> RealtimeMediaStream

    /// Disconnects realtime while retaining the local media preview.
    func disconnect() async

    /// Disconnects realtime for a business reason while retaining usable local media.
    ///
    /// - Parameter reason: The disconnect reason, such as a display orientation change.
    func disconnect(
        reason: RealtimeReason
    ) async

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
    ///   - context: The generation conditions; required initially. Later calls may pass `nil` to reuse cached
    ///     conditions.
    ///   - faceRestoration: Whether to restore the original face; each call sends this setting.
    ///
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
    ///
    /// - Returns: The remote media stream for the current RTC connection.
    ///
    /// - Throws: An error on invalid local stream, connection failure, or generation startup failure.
    func startGeneration(
        localStream: RealtimeMediaStream,
        context: RealtimeContext?,
        faceRestoration: Bool
    ) async throws -> RealtimeMediaStream
}

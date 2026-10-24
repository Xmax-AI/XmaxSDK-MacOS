//
//  StreamControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines unified transport capabilities exposed to Core.
protocol StreamControlling: Sendable {

    /// The current media baseline and upstream and downstream tiers.
    var qualityConfiguration: QualityConfiguration? { get }

    /// Prepares upstream and downstream tiers from media baseline and model history.
    ///
    /// - Parameters:
    ///   - baseline: The original local media output format, unchanged by tier adjustments.
    ///   - model: The model identifier isolating tier history.
    ///
    /// - Returns: The initial upstream and downstream configuration for this connection.
    func prepareQuality(
        baseline: RealtimeVideoFormat,
        model: String
    ) -> QualityConfiguration

    /// Sets the internal tier adjustment callback without affecting public network quality observation.
    ///
    /// - Parameter listener: Receives network quality and monotonic sample time; nil removes it.
    func setAdaptiveQualityListener(
        _ listener: (@Sendable (RealtimeNetworkQuality, TimeInterval) -> Void)?
    )

    /// Consumes the current network sample and returns candidate tiers.
    ///
    /// - Parameters:
    ///   - quality: The current upstream and downstream network quality.
    ///   - sampledAt: The monotonic sample time in seconds.
    ///
    /// - Returns: The candidate tiers meeting consecutive sample and cooldown requirements.
    func proposeQuality(
        _ quality: RealtimeNetworkQuality,
        sampledAt: TimeInterval
    ) -> QualityChange

    /// Commits tier adjustment results and saves history on success.
    ///
    /// - Parameters:
    ///   - downlink: true indicates downstream; false indicates upstream.
    ///   - level: The attempted tier in 1...5.
    ///   - success: Whether configuration applied successfully.
    func completeQuality(
        downlink: Bool,
        level: Int,
        success: Bool
    )

    /// Clears the consecutive sampling window.
    func resetQualitySamples()

    /// Whether a generation task is starting or running.
    var hasGenerationTask: Bool { get }

    /// The current remote generated audio playback volume.
    var remoteAudioVolume: Float { get }

    /// Sets realtime video encoder configuration.
    ///
    /// - Parameter videoFormat: The width, height, and frame rate for RTC encoding.
    ///
    /// - Throws: An error on invalid video format or RTC encoding configuration failure.
    func setVideoEncoderConfig(
        _ videoFormat: RealtimeVideoFormat
    ) throws

    /// Sets the upstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil before publication or after disconnect. Pass nil to
    ///   clear it.
    func setUplinkVideoStatisticsListener(
        _ listener: UplinkVideoStatisticsListener?
    )

    /// Sets the downstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil when the result stream is cleared. Pass nil to
    ///   clear it.
    func setDownlinkVideoStatisticsListener(
        _ listener: DownlinkVideoStatisticsListener?
    )

    /// Sets the network quality listener; nil clears it.
    ///
    /// - Parameter listener: The listener receiving upstream and downstream quality events;
    ///   Pass nil to clear the current listener.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    )

    /// Sets the device performance alarm listener; nil clears it.
    ///
    /// - Parameter listener: The listener receiving device performance limitation and recovery events;
    ///   Pass nil to clear the current listener.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    )

    /// Sets the playback volume for remote generated audio.
    ///
    /// - Parameter volume: The validated volume in `0...1`.
    ///
    /// - Throws: An error if RTC volume configuration fails.
    func setRemoteAudioVolume(
        _ volume: Float
    ) throws

    /// Joins an RTC room and publishes local media.
    ///
    /// - Parameters:
    ///   - connection: The RTC room, user, token, and target bot information.
    ///   - includeLocalAudio: Whether to publish local audio alongside video.
    ///   - ensureActive: The callback validating connection operation identity across asynchronous boundaries;
    ///     Should throw cancellation if invalid.
    ///
    /// - Throws: An error on connection cancellation or RTC join, room configuration, or local publication
    ///   failure.
    func connect(
        connection: RealtimeSessionConnection,
        includeLocalAudio: Bool,
        beforePublication: @escaping @Sendable () async throws -> Void,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws

    /// Clears generation, local publication, and remote subscription state, then leaves the RTC room;
    /// returns safely without an active room.
    func disconnect() async

    /// Pushes local external video during an active generation task; ignores frames otherwise.
    ///
    /// - Parameter frame: The local video frame prepared for RTC.
    ///
    /// - Throws: An error if RTC resources are unready or frame conversion fails.
    func pushLocalVideoFrame(
        _ frame: VideoFrame
    ) throws

    /// Pushes a local external audio frame.
    ///
    /// - Parameter frame: The PCM frame prepared for RTC;
    ///   Ignored before local audio publication.
    ///
    /// - Throws: An error if RTC resources are unready or audio frame conversion fails.
    func pushLocalAudioFrame(
        _ frame: AudioFrame
    ) throws

    /// Creates a generation task, sends its start signal, and begins result confirmation.
    ///
    /// - Parameters:
    ///   - taskID: The unique generation task identifier.
    ///   - videoFormat: The server generation video format.
    ///   - targetSize: The returned pixel dimensions; `nil` preserves generation dimensions.
    ///   - context: The generation conditions, including reference image and prompt.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve source aspect ratio and pad the canvas using contain mode.
    ///
    /// - Returns: The task awaiting remote result stream publication confirmation.
    ///
    /// - Throws: An error on invalid task parameters, unready room, existing generation task, signal failure, or send
    ///   timeout.
    func beginGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize?,
        context: RealtimeContext,
        faceRestoration: Bool,
        paddingContain: Bool
    ) async throws -> Task<Void, any Error>

    /// Subscribes to generation audio after the first remote frame becomes displayable.
    ///
    /// - Throws: An error if the result stream is unconfirmed or RTC volume or subscription configuration fails.
    func activateRemoteAudio() throws

    /// Sends condition updates for the current generation task.
    ///
    /// - Parameters:
    ///   - taskID: The unique generation task identifier.
    ///   - videoFormat: The server generation video format.
    ///   - targetSize: The returned pixel dimensions; `nil` preserves generation dimensions.
    ///   - context: The generation conditions, including reference image and prompt.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve source aspect ratio and pad the canvas using contain mode.
    ///
    /// - Throws: An error on unready room, invalid parameters, or signal submission failure.
    func updateGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize?,
        context: RealtimeContext,
        faceRestoration: Bool,
        paddingContain: Bool
    ) async throws

    /// Adjusts return dimensions without restarting generation.
    ///
    /// - Parameters:
    ///   - taskID: The current generation task identifier.
    ///   - targetSize: The returned integer-pixel dimensions.
    ///   - ensureActive: Checks current configuration operation validity before sending.
    ///
    /// - Throws: An error on cancellation, unready room, or signal send failure.
    func changeTargetSize(
        taskID: String,
        targetSize: CGSize,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws

    /// Stops generation and clears the remote result stream.
    ///
    /// - Parameter taskID: The generation task identifier to stop; an empty string stops
    ///   the current task.
    ///
    /// - Throws: An error if sending the RTC stop signal fails.
    func stopGeneration(
        taskID: String
    ) async throws

    /// Sends a generation task's interaction trajectory.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier receiving the trajectory.
    ///   - points: The trajectory points to send; empty arrays are ignored.
    ///
    /// - Throws: An error on unready RTC room, invalid task identity, or trajectory signal
    ///   failure.
    func sendTracks(
        taskID: String,
        points: [RealtimePoint]
    ) async throws
}

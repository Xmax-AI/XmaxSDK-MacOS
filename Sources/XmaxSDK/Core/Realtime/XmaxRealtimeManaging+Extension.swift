//
//  XmaxRealtimeManaging+Extension.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Provides common defaults for local stream creation and generation calls.
public extension XmaxRealtimeManaging {

    /// Provides empty observation for custom managers without a local capture implementation.
    func setLocalMediaFrameListener(
        tracks: Set<RealtimeMediaTrack>,
        _ listener: RealtimeMediaFrameListener?
    ) async {}

    /// Observes both tracks of the local camera stream, or removes the listener when nil.
    func setLocalMediaFrameListener(
        _ listener: RealtimeMediaFrameListener?
    ) async {
        await setLocalMediaFrameListener(tracks: [.audio, .video], listener)
    }

    /// Binds external video retaining the source's frame rate and encoding settings.
    ///
    /// - Parameter source: The caller-owned video source.
    ///
    /// - Returns: The bound local video stream.
    ///
    /// - Throws: An error on invalid media state, unsupported dimensions, or binding failure.
    func createExternalVideoStream(
        source: any RealtimeExternalVideoSource
    ) async throws -> RealtimeMediaStream {
        try await createExternalVideoStream(
            source: source,
            videoFormat: nil
        )
    }

    /// Creates a camera stream using the model's default format when omitted.
    ///
    /// - Parameters:
    ///   - videoFormat: The target format after rotation, including frame rate and encoding settings.
    ///   - captureFormat: Preferred input dimensions before rotation; nil derives them from the target.
    ///   - camera: The camera selection; defaults to a front-facing preference.
    ///   - microphone: The microphone used while connected; disabled by default.
    ///   - rotation: Clockwise rotation before mirroring; zero by default.
    ///   - mirror: Whether to mirror the shared pixels; nil mirrors front cameras and unknown-facing default cameras.
    ///   - warmupMs: Additional warmup before publication, in milliseconds; finite, nonnegative, and zero by default.
    ///
    /// - Returns: The local stream shared by preview, frame observation, and RTC.
    ///
    /// - Throws: An error on invalid configuration, denied permission, conflicting operations, or capture failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat? = nil,
        captureFormat: CameraCaptureFormat? = nil,
        camera: RealtimeCamera = .position(.front),
        microphone: RealtimeMicrophone = .disabled,
        rotation: CameraRotation = .degrees0,
        mirror: Bool? = nil,
        warmupMs: Double = 0
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: videoFormat ?? configuration.model.defaultCameraVideoFormat,
            captureFormat: captureFormat,
            camera: camera,
            microphone: microphone,
            rotation: rotation,
            mirror: mirror,
            warmupMs: warmupMs
        )
    }

    /// Creates a camera stream with a predefined target and the model's recommended frame rate.
    ///
    /// Other options have the same behavior as the custom-video-format overload.
    ///
    /// - Throws: An error if the model does not support the predefined format or capture cannot start.
    func createLocalCameraStream(
        videoFormat: RealtimeCameraPreset,
        captureFormat: CameraCaptureFormat? = nil,
        camera: RealtimeCamera = .position(.front),
        microphone: RealtimeMicrophone = .disabled,
        rotation: CameraRotation = .degrees0,
        mirror: Bool? = nil,
        warmupMs: Double = 0
    ) async throws -> RealtimeMediaStream {
        guard let format = configuration.model.supportedVideoFormats.first(where: { $0.size == videoFormat.size }) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Model does not support the requested camera format"
            )
        }
        return try await createLocalCameraStream(
            videoFormat: format,
            captureFormat: captureFormat,
            camera: camera,
            microphone: microphone,
            rotation: rotation,
            mirror: mirror,
            warmupMs: warmupMs
        )
    }

    /// Starts or updates generation using cached conditions.
    ///
    /// Initial generation has no cached conditions; use the overload accepting `context` first.
    ///
    /// - Parameter faceRestoration: Whether to restore the original face; disabled by default.
    ///
    /// - Throws: An error if no reusable conditions exist or generation startup or update fails.
    func startGeneration(
        faceRestoration: Bool = false
    ) async throws {
        try await startGeneration(
            context: nil,
            faceRestoration: faceRestoration
        )
    }

    /// Starts or updates generation with face restoration disabled by default.
    ///
    /// - Parameter context: The generation conditions; `nil` reuses cached conditions.
    ///
    /// - Throws: An error if conditions are invalid or generation startup or update fails.
    func startGeneration(
        context: RealtimeContext?
    ) async throws {
        try await startGeneration(
            context: context,
            faceRestoration: false
        )
    }

    /// Connects with the current local stream when needed and starts generation with face restoration disabled.
    ///
    /// - Parameters:
    ///   - localStream: The local media stream created and owned by this manager.
    ///   - context: The generation conditions; required for initial generation.
    ///
    /// - Returns: The remote media stream for the current connection.
    ///
    /// - Throws: An error on invalid local stream, connection failure, or generation startup failure.
    func startGeneration(
        localStream: RealtimeMediaStream,
        context: RealtimeContext?
    ) async throws -> RealtimeMediaStream {
        try await startGeneration(
            localStream: localStream,
            context: context,
            faceRestoration: false
        )
    }

    /// Connects when needed and starts generation with the current local stream and cached conditions.
    ///
    /// Initial generation has no cached conditions; use the overload accepting `context` first.
    ///
    /// - Parameters:
    ///   - localStream: The local media stream created and owned by this manager.
    ///   - faceRestoration: Whether to restore the original face; disabled by default.
    ///
    /// - Returns: The remote media stream for the current RTC connection.
    ///
    /// - Throws: An error on missing reusable conditions, invalid local stream, or connection or generation startup
    ///   failure.
    func startGeneration(
        localStream: RealtimeMediaStream,
        faceRestoration: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await startGeneration(
            localStream: localStream,
            context: nil,
            faceRestoration: faceRestoration
        )
    }
}

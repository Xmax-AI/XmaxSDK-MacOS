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

    /// Creates a camera stream using a preset and the model's recommended frame rate.
    ///
    /// - Parameters:
    ///   - preset: The camera resolution, which must be supported by the model.
    ///   - camera: The camera selection, which defaults to the system camera.
    ///   - microphone: The initial microphone selection, disabled by default.
    ///   - mirror: Whether to mirror local preview and upstream camera video; disabled by default.
    ///
    /// - Returns: A media stream containing the local camera track.
    ///
    /// - Throws: An error if the preset is unsupported, permission is denied, an operation
    ///   conflicts, or capture cannot start.
    func createLocalCameraStream(
        preset: RealtimeCameraPreset,
        camera: RealtimeCamera = .systemDefault,
        microphone: RealtimeMicrophone = .disabled,
        mirror: Bool = false
    ) async throws -> RealtimeMediaStream {
        guard
            let format = configuration.model.supportedVideoFormats.first(
                where: {
                    $0.size == preset.size
                }
            )
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Model does not support the requested camera preset"
            )
        }

        return try await createLocalCameraStream(
            videoFormat: format,
            camera: camera,
            microphone: microphone,
            mirror: mirror
        )
    }

    /// Creates a default-camera stream and starts its preview.
    ///
    /// - Parameters:
    ///   - videoFormat: The camera capture and encoding format.
    ///   - microphone: The initial microphone selection, disabled by default.
    ///   - mirror: Whether to mirror local preview and upstream camera video; disabled by default.
    ///
    /// - Returns: A media stream containing the local camera video track.
    ///
    /// - Throws: An error if configuration is invalid, permission is denied, an operation
    ///   conflicts, or capture cannot start.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        microphone: RealtimeMicrophone = .disabled,
        mirror: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: videoFormat,
            camera: .systemDefault,
            microphone: microphone,
            mirror: mirror
        )
    }

    /// Creates a camera stream with the specified format and microphone disabled.
    ///
    /// - Parameters:
    ///   - videoFormat: A camera output format supported by the model.
    ///   - camera: The camera selection.
    ///   - mirror: Whether to mirror local preview and upstream camera video; disabled by default.
    ///
    /// - Returns: A media stream containing the local camera track.
    ///
    /// - Throws: An error on permission, device configuration, or capture startup failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        camera: RealtimeCamera,
        mirror: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: videoFormat,
            camera: camera,
            microphone: .disabled,
            mirror: mirror
        )
    }

    /// Creates an unmirrored camera stream with explicit device and microphone selections.
    ///
    /// - Parameters:
    ///   - videoFormat: The camera capture and encoding format.
    ///   - camera: The camera selection.
    ///   - microphone: The initial microphone selection.
    ///
    /// - Returns: A media stream containing the local camera track.
    ///
    /// - Throws: An error on permission, device configuration, or capture startup failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        camera: RealtimeCamera,
        microphone: RealtimeMicrophone
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: videoFormat,
            camera: camera,
            microphone: microphone,
            mirror: false
        )
    }

    /// Creates a local camera stream using the current model's default landscape format.
    ///
    /// - Parameters:
    ///   - camera: The camera selection.
    ///   - microphone: The initial microphone selection, disabled by default.
    ///   - mirror: Whether to mirror local preview and upstream camera video; disabled by default.
    ///
    /// - Returns: A media stream containing the local camera track.
    ///
    /// - Throws: An error on permission, device configuration, or capture startup failure.
    func createLocalCameraStream(
        camera: RealtimeCamera = .systemDefault,
        microphone: RealtimeMicrophone = .disabled,
        mirror: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: configuration.model.defaultCameraVideoFormat,
            camera: camera,
            microphone: microphone,
            mirror: mirror
        )
    }

    /// Creates a camera stream using the legacy camera identifier label.
    @available(*, deprecated, message: "Use .systemDefault or .device(id:) for camera and place mirror after microphone.")
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        mirror: Bool = false,
        microphone: RealtimeMicrophone = .disabled
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: videoFormat,
            camera: RealtimeCamera(deviceID: deviceID),
            microphone: microphone,
            mirror: mirror
        )
    }

    /// Creates a preset camera stream using the legacy camera identifier label.
    @available(*, deprecated, message: "Use .systemDefault or .device(id:) for camera and place mirror after microphone.")
    func createLocalCameraStream(
        preset: RealtimeCameraPreset,
        deviceID: String?,
        mirror: Bool = false,
        microphone: RealtimeMicrophone = .disabled
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            preset: preset,
            camera: RealtimeCamera(deviceID: deviceID),
            microphone: microphone,
            mirror: mirror
        )
    }

    /// Creates a default-format camera stream using the legacy camera identifier label.
    @available(*, deprecated, message: "Use .systemDefault or .device(id:) for camera and place mirror after microphone.")
    func createLocalCameraStream(
        deviceID: String?,
        mirror: Bool = false,
        microphone: RealtimeMicrophone = .disabled
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            camera: RealtimeCamera(deviceID: deviceID),
            microphone: microphone,
            mirror: mirror
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

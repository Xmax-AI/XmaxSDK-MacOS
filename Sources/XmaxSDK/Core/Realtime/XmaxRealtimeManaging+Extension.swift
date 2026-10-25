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
    ///   - deviceID: The initial camera device identifier; `nil` selects the system default.
    ///   - mirror: Whether to mirror local preview and upstream camera video; disabled by default.
    ///   - useMicrophone: Whether to capture microphone audio while connected.
    ///
    /// - Returns: A media stream containing the local camera track.
    ///
    /// - Throws: An error if the preset is unsupported, permission is denied, an operation
    ///   conflicts, or capture cannot start.
    func createLocalCameraStream(
        preset: RealtimeCameraPreset,
        deviceID: String? = nil,
        mirror: Bool = false,
        useMicrophone: Bool = false
    ) async throws -> RealtimeMediaStream {
        guard
            let format = options.model.supportedVideoFormats.first(
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
            deviceID: deviceID,
            mirror: mirror,
            useMicrophone: useMicrophone
        )
    }

    /// Creates a default-camera stream and starts its preview.
    ///
    /// - Parameters:
    ///   - videoFormat: The camera capture and encoding format.
    ///   - mirror: Whether to mirror local preview and upstream camera video; disabled by default.
    ///   - useMicrophone: Whether to capture microphone audio while connected. The default is
    ///     `false`.
    ///
    /// - Returns: A media stream containing the local camera video track.
    ///
    /// - Throws: An error if configuration is invalid, a required permission is denied, an
    ///   operation conflicts, or capture cannot start.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        mirror: Bool = false,
        useMicrophone: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: videoFormat,
            deviceID: nil,
            mirror: mirror,
            useMicrophone: useMicrophone
        )
    }

    /// Creates a camera stream with the specified format and no microphone.
    ///
    /// - Parameters:
    ///   - videoFormat: A camera output format supported by the model.
    ///   - deviceID: The device identifier; an empty value uses the system default camera.
    ///   - mirror: Whether to mirror local preview and upstream camera video; disabled by default.
    ///
    /// - Returns: The media stream containing the local camera track.
    ///
    /// - Throws: An error on permission, device configuration, or capture startup failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        mirror: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: videoFormat,
            deviceID: deviceID,
            mirror: mirror,
            useMicrophone: false
        )
    }

    /// Creates an unmirrored camera stream with explicit device and microphone settings.
    ///
    /// - Parameters:
    ///   - videoFormat: The camera capture and encoding format.
    ///   - deviceID: The camera identifier; `nil` selects the system default.
    ///   - useMicrophone: Whether to capture microphone audio while connected.
    ///
    /// - Returns: The media stream containing the local camera track.
    ///
    /// - Throws: An error on permission, device configuration, or capture startup failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        useMicrophone: Bool
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: videoFormat,
            deviceID: deviceID,
            mirror: false,
            useMicrophone: useMicrophone
        )
    }

    /// Creates a local camera stream using the current model's default landscape format.
    ///
    /// - Parameters:
    ///   - deviceID: The device identifier; an empty value uses the system default camera.
    ///   - mirror: Whether to mirror local preview and upstream camera video; disabled by default.
    ///   - useMicrophone: Whether to use the microphone; disabled by default.
    ///
    /// - Returns: The media stream containing the local camera track.
    ///
    /// - Throws: An error on permission, device configuration, or capture startup failure.
    func createLocalCameraStream(
        deviceID: String? = nil,
        mirror: Bool = false,
        useMicrophone: Bool = false
    ) async throws -> RealtimeMediaStream {
        try await createLocalCameraStream(
            videoFormat: options.model.defaultCameraVideoFormat,
            deviceID: deviceID,
            mirror: mirror,
            useMicrophone: useMicrophone
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

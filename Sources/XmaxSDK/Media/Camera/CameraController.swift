//
//  CameraController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import Foundation

/// Coordinates SDK camera and microphone capture, preview, and RTC input.
final class CameraController: CameraControlling, @unchecked Sendable {

    /// The local camera track identifier.
    private static let localVideoTrackID = "video0"

    /// The RTC media adapter.
    private let rtcManager: any RtcManaging

    /// The camera and microphone permission manager.
    private let permissionManager: any PermissionManaging

    /// The independent video and microphone capture components.
    private let cameraCapture: any CameraCaptureControlling
    private let microphoneCapture: any MicrophoneCaptureControlling

    /// The model media sizing service.
    private let mediaService: any MediaServicing

    /// The camera media failure handler.
    private let errorListener: XmaxErrorListener

    /// Receives processed camera and microphone frames for RTC publication.
    private let videoFrameListener: MediaVideoFrameListener
    private let audioFrameListener: MediaAudioFrameListener

    /// The internal preview readiness handler.
    private var previewReadyHandler: CameraPreviewReadyHandler?

    /// The lock protecting camera, capture, and preview state.
    private let stateLock = NSLock()

    /// The lock serializing microphone start and stop operations.
    private let audioOperationLock = NSRecursiveLock()

    /// Serializes format changes across suspension points.
    @MainActor private var formatUpdateTask: Task<Void, any Error>?

    /// The active camera track.
    private var activeTrack: RealtimeVideoTrack?

    /// The camera preview resources.
    private var preview: DecodedVideoPreviewPresenter?
    private var previewDispatcher: DecodedVideoPreviewDispatcher?

    /// Whether capture can support local media readiness.
    private var isCaptureReady = false

    /// Whether a preview view is attached.
    private var isPreviewAttached = false

    /// Whether this camera input requests microphone access.
    private var storedUseMicrophone = false

    /// Whether the local capture session has an active microphone input.
    private var isMicrophoneCapturing = false

    /// The active local camera video track, or nil before creation.
    var currentTrack: RealtimeVideoTrack? {
        stateLock.withLock { activeTrack }
    }

    /// Whether the current camera stream is configured to use the microphone.
    var useMicrophone: Bool {
        stateLock.withLock { activeTrack != nil && storedUseMicrophone }
    }

    /// Creates a camera controller with system permission and capture components.
    ///
    /// - Parameters:
    ///   - rtcManager: The component configuring RTC tracks for captured media.
    ///   - mediaService: The service providing model dimension rules.
    ///   - errorListener: The callback receiving capture runtime errors.
    @MainActor
    convenience init(
        rtcManager: any RtcManaging,
        mediaService: any MediaServicing = MediaService(),
        videoFrameListener: @escaping MediaVideoFrameListener,
        audioFrameListener: @escaping MediaAudioFrameListener,
        errorListener: @escaping XmaxErrorListener
    ) {
        self.init(
            rtcManager: rtcManager,
            permissionManager: PermissionManager(),
            mediaService: mediaService,
            cameraCapture: CameraCaptureController(),
            microphoneCapture: MicrophoneCaptureController(),
            videoFrameListener: videoFrameListener,
            audioFrameListener: audioFrameListener,
            errorListener: errorListener
        )
    }

    /// Creates a camera controller with the specified dependencies.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC media adapter.
    ///   - permissionManager: The camera and microphone permission component.
    ///   - mediaService: The model dimension rules service.
    ///   - cameraCapture: The system video capture component.
    ///   - microphoneCapture: The system microphone capture component.
    ///   - errorListener: The callback receiving capture runtime errors.
    init(
        rtcManager: any RtcManaging,
        permissionManager: any PermissionManaging,
        mediaService: any MediaServicing,
        cameraCapture: any CameraCaptureControlling,
        microphoneCapture: any MicrophoneCaptureControlling,
        videoFrameListener: @escaping MediaVideoFrameListener = { _ in },
        audioFrameListener: @escaping MediaAudioFrameListener = { _ in },
        errorListener: @escaping XmaxErrorListener = { _ in }
    ) {
        self.rtcManager = rtcManager
        self.permissionManager = permissionManager
        self.mediaService = mediaService
        self.cameraCapture = cameraCapture
        self.microphoneCapture = microphoneCapture
        self.videoFrameListener = videoFrameListener
        self.audioFrameListener = audioFrameListener
        self.errorListener = errorListener
    }

    /// Lists devices available for camera stream creation or switching.
    ///
    /// - Returns: The currently available camera devices.
    func listCameraDevices() -> [CameraDevice] {
        cameraCapture.listCameraDevices()
    }

    /// Resolves an explicit device or system default without silently replacing an unavailable explicit selection.
    ///
    /// - Parameter deviceID: The specified device identifier; an empty value uses the default device.
    ///
    /// - Returns: The available target device.
    ///
    /// - Throws: A media error if the specified device is unavailable or no camera exists.
    private func resolveDevice(
        _ deviceID: String?
    ) throws -> CameraDevice {
        let devices = cameraCapture.listCameraDevices()
        let device: CameraDevice?
        if let deviceID {
            device = devices.first { $0.id == deviceID }
        } else {
            device = devices.first { $0.isDefault } ?? devices.first
        }
        guard let device else {
            throw XmaxError(
                code: .mediaError,
                message: "The requested camera is unavailable"
            )
        }
        return device
    }

    /// Reports ready capture and a bound preview without requiring hidden native views to render.
    ///
    /// - Parameter handler: The readiness callback; an empty value clears it.
    func setPreviewReadyHandler(
        _ handler: CameraPreviewReadyHandler?
    ) {
        let track = stateLock.withLock {
            previewReadyHandler = handler
            return activeTrack
        }
        if let track { notifyPreviewReady(for: track) }
    }

    /// Creates and starts a local camera stream.
    ///
    /// - Parameters:
    ///   - videoFormat: The requested dimensions, frame rate, and encoding configuration; dimensions follow model
    ///     rules.
    ///   - deviceID: The initial device identifier; an empty value uses the system default camera.
    ///   - mirror: Whether to mirror camera preview and upstream encoding; disabled by default.
    ///   - useMicrophone: Whether to request microphone permission and allow capture when realtime connects.
    ///
    /// - Returns: The media stream containing the local camera video track.
    ///
    /// - Throws: An error on an existing camera stream, invalid format, insufficient permissions, or capture startup
    ///   failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
        mirror: Bool = false,
        useMicrophone: Bool = false
    ) async throws -> RealtimeMediaStream {
        guard currentTrack == nil else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Stop the current local camera stream before creating another one"
            )
        }
        let resolvedFormat = try resolveVideoFormat(videoFormat)
        try await permissionManager.ensureCameraPermission()
        let device = try resolveDevice(deviceID)
        let track = RealtimeVideoTrack(
            id: Self.localVideoTrackID,
            videoFormat: resolvedFormat,
            device: device
        )
        do {
            if useMicrophone {
                try await permissionManager.ensureMicrophonePermission()
            }
            try Task.checkCancellation()
            try rtcManager.useExternalVideoSource(useTexture: true)
            try rtcManager.configureLocalVideoMirror(mirror)
            let preview = await makePreview(
                for: track,
                mirrored: mirror
            )
            let dispatcher = DecodedVideoPreviewDispatcher(presenter: preview)
            stateLock.withLock {
                activeTrack = track
                self.preview = preview
                previewDispatcher = dispatcher
                storedUseMicrophone = useMicrophone
                isCaptureReady = false
                isPreviewAttached = false
            }
            try await cameraCapture.start(
                videoFormat: VideoFormat(
                    width: resolvedFormat.width,
                    height: resolvedFormat.height,
                    pixelFormat: .nv12
                ),
                frameRate: resolvedFormat.fps,
                deviceID: device.id,
                frameListener: { [weak self] frame in
                    guard let self, currentTrack === track else { return }
                    dispatcher.enqueue(frame)
                    try videoFrameListener(frame)
                },
                previewReadyListener: { [weak self] in
                    guard let self else { return }
                    let current = stateLock.withLock {
                        guard activeTrack === track else { return false }
                        isCaptureReady = true
                        return true
                    }
                    if current { notifyPreviewReady(for: track) }
                },
                errorListener: { [weak self] error in
                    guard let self, currentTrack === track else { return }
                    errorListener(error)
                }
            )
            try Task.checkCancellation()
            return RealtimeMediaStream(
                id: StreamID.local.rawValue,
                videoTrack: track
            )
        } catch {
            await stopLocalCameraStream()
            throw XmaxError.from(error)
        }
    }

    /// Prepares the RTC audio track before joining and starts capture when the microphone is enabled.
    ///
    /// - Throws: An error on RTC audio source configuration or microphone capture startup failure.
    func startMicrophoneCapture() throws {
        try audioOperationLock.withLock {
            guard stateLock.withLock({ activeTrack != nil && !isMicrophoneCapturing }) else { return }
            // Agora requires the custom track to exist before joining, even for a microphone enabled later.
            try rtcManager.startExternalAudioSource()
            guard stateLock.withLock({ storedUseMicrophone }) else { return }
            try microphoneCapture.start(frameListener: audioFrameListener)
            stateLock.withLock { isMicrophoneCapturing = true }
        }
    }

    /// Stops microphone capture while retaining configuration for the next connection.
    func stopMicrophoneCapture() {
        audioOperationLock.withLock {
            guard stateLock.withLock({ isMicrophoneCapturing }) else { return }
            microphoneCapture.stop()
            stateLock.withLock { isMicrophoneCapturing = false }
        }
    }

    /// Routes microphone selection to the system capture session.
    func switchMicrophone(to deviceID: String?) throws {
        try audioOperationLock.withLock {
            try microphoneCapture.selectDevice(deviceID)
        }
    }

    /// Observes physical PCM input level on the main actor.
    @MainActor
    func setMicrophoneLevelListener(_ listener: RealtimeMicrophoneLevelListener?) {
        microphoneCapture.setLevelListener(listener)
    }

    /// Changes microphone intent while preventing a late permission reply from restarting closed capture.
    func setMicrophoneEnabled(
        _ enabled: Bool,
        capture: Bool,
        ensureCurrent: @escaping @Sendable () throws -> Void
    ) async throws {
        guard let track = stateLock.withLock({ activeTrack }) else {
            throw XmaxError(code: .invalidConfiguration, message: "Local camera stream is unavailable")
        }
        if enabled { try await permissionManager.ensureMicrophonePermission() }
        try audioOperationLock.withLock {
            try ensureCurrent()
            guard stateLock.withLock({ activeTrack === track }) else {
                throw XmaxError(code: .cancelled, message: "Local camera stream was stopped")
            }
            let previous = stateLock.withLock { storedUseMicrophone }
            if enabled {
                stateLock.withLock { storedUseMicrophone = true }
                do {
                    if capture { try startMicrophoneCapture() }
                } catch {
                    stopMicrophoneCapture()
                    stateLock.withLock { storedUseMicrophone = previous }
                    throw error
                }
            } else {
                stopMicrophoneCapture()
                stateLock.withLock { storedUseMicrophone = false }
            }
        }
    }

    /// Stops camera and microphone capture and releases the track and local preview resources.
    func stopLocalCameraStream() async {
        let (track, preview, dispatcher) = audioOperationLock.withLock {
            stopMicrophoneCapture()
            return stateLock.withLock {
                let resources = (activeTrack, preview, previewDispatcher)
                activeTrack = nil
                preview = nil
                previewDispatcher = nil
                previewReadyHandler = nil
                storedUseMicrophone = false
                isCaptureReady = false
                isPreviewAttached = false
                return resources
            }
        }
        await cameraCapture.stop()
        dispatcher?.reset()
        await MainActor.run {
            if let track { VideoRenderRegistry.unregister(track) }
            preview?.clear()
        }
    }

    /// Updates a camera format while retaining the current track and preview binding.
    ///
    /// - Throws: An error if no camera exists, the format is unsupported, or capture configuration fails.
    @MainActor
    func updateVideoFormat(
        _ videoFormat: RealtimeVideoFormat
    ) async throws {
        guard let track = currentTrack else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Camera preview is not started"
            )
        }
        let previous = formatUpdateTask
        let task = Task { @MainActor [self] in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard currentTrack === track else { throw CancellationError() }
            let resolved = try resolveVideoFormat(videoFormat)
            let output = try VideoFormat(
                width: resolved.width,
                height: resolved.height,
                pixelFormat: .nv12
            )
            if resolved != track.videoFormat {
                try await cameraCapture.updateFormat(
                    output,
                    frameRate: resolved.fps
                )
            }
            try stateLock.withLock {
                guard activeTrack === track else { throw CancellationError() }
                track.updateVideoFormat(resolved)
            }
        }
        formatUpdateTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Switches to the specified camera device while retaining the current video track.
    ///
    /// - Returns: The media stream containing the updated camera track.
    ///
    /// - Throws: An error if no camera stream is active or device switching fails.
    func switchCamera(
        to deviceID: String
    ) async throws -> RealtimeMediaStream {
        guard let track = currentTrack else {
            throw XmaxError(
                code: .rtcError,
                message: "Local camera preview is not started"
            )
        }
        let device = try resolveDevice(deviceID)
        try await cameraCapture.switchCamera(to: device.id)
        track.updateDevice(device)
        return RealtimeMediaStream(
            id: StreamID.local.rawValue,
            videoTrack: track
        )
    }

}

private extension CameraController {

    /// Creates and registers a preview binding for the camera track.
    ///
    /// - Parameters:
    ///   - track: The local camera track to preview.
    ///   - mirrored: Whether the camera stream requests mirrored presentation.
    ///
    /// - Returns: The decoded preview presenter.
    @MainActor
    func makePreview(
        for track: RealtimeVideoTrack,
        mirrored: Bool
    ) -> DecodedVideoPreviewPresenter {
        let preview = DecodedVideoPreviewPresenter()
        VideoRenderRegistry.register(
            track,
            binding: VideoRenderBinding(
                attachHandler: { [weak self] view, contentMode in
                    guard let videoView = view as? XmaxRealtimeVideoView else {
                        throw XmaxError(
                            code: .invalidConfiguration,
                            message: "Camera tracks require an XmaxRealtimeVideoView"
                        )
                    }
                    preview.attach(
                        to: videoView,
                        contentMode: contentMode,
                        sourceMirrored: mirrored
                    )
                    self?.stateLock.withLock { self?.isPreviewAttached = true }
                    self?.notifyPreviewReady(for: track)
                },
                detachHandler: { [weak self] view in
                    if let videoView = view as? XmaxRealtimeVideoView { preview.detach(from: videoView) }
                    self?.stateLock.withLock { self?.isPreviewAttached = false }
                }
            )
        )
        return preview
    }

    /// Reports readiness once capture is active and the preview is bound.
    ///
    /// - Parameter track: The camera track whose validity must be checked.
    func notifyPreviewReady(
        for track: RealtimeVideoTrack
    ) {
        let shouldNotify = stateLock.withLock {
            activeTrack === track && isCaptureReady && isPreviewAttached && previewReadyHandler != nil
        }
        guard shouldNotify else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let handler = stateLock.withLock { () -> CameraPreviewReadyHandler? in
                guard activeTrack === track, isCaptureReady, isPreviewAttached else {
                    return nil
                }
                let handler = previewReadyHandler
                previewReadyHandler = nil
                return handler
            }
            handler? { [weak self] in
                guard let self else { return false }
                return stateLock.withLock {
                    activeTrack === track
                }
            }
        }
    }

    /// Resolves the actual camera output format using model dimension rules.
    ///
    /// - Parameter videoFormat: The requested camera video format.
    ///
    /// - Returns: The valid output format retaining frame rate and encoding options.
    ///
    /// - Throws: An error if input format is invalid or the model does not support target dimensions.
    func resolveVideoFormat(
        _ videoFormat: RealtimeVideoFormat
    ) throws -> RealtimeVideoFormat {
        try videoFormat.validate()
        let targetSize = try mediaService.resolveMediaSize(
            CGSize(
                width: videoFormat.width,
                height: videoFormat.height
            ),
            source: .camera
        )
        let resolvedFormat = videoFormat.resized(
            width: Int(targetSize.width),
            height: Int(targetSize.height)
        )
        try resolvedFormat.validate()
        return resolvedFormat
    }
}

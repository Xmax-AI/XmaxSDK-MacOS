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

/// Coordinates RTC camera capture and SDK local preview.
final class CameraController: CameraControlling, @unchecked Sendable {

    /// The local camera track identifier.
    private static let localVideoTrackID = "video0"

    /// The RTC media adapter.
    private let rtcManager: any RtcManaging

    /// The camera and microphone permission manager.
    private let permissionManager: any PermissionManaging

    /// The camera capture manager.
    private let captureManager: any CameraCaptureManaging

    /// The model media sizing service.
    private let mediaService: any MediaServicing

    /// The camera video frame handler.
    private let videoFrameListener: MediaVideoFrameListener

    /// The camera media failure handler.
    private let errorListener: XmaxErrorListener

    /// The internal preview readiness handler.
    private var previewReadyHandler: CameraPreviewReadyHandler?

    /// The lock protecting camera, capture, and preview state.
    private let stateLock = NSLock()

    /// The lock serializing microphone start and stop operations.
    private let audioOperationLock = NSRecursiveLock()

    /// The active camera track.
    private var activeTrack: RealtimeVideoTrack?

    /// The camera preview resources.
    private var preview: Preview?

    /// Whether capture can support local media readiness.
    private var isCaptureReady = false

    /// Whether a preview view is attached.
    private var isPreviewAttached = false

    /// Whether this camera input requests microphone access.
    private var storedUseMicrophone = false

    /// Whether RTC microphone capture is active.
    private var isMicrophoneCapturing = false

    /// Creates a camera controller with system permission and capture components.
    ///
    /// - Parameters:
    ///   - rtcManager: The component configuring RTC external video and microphone input.
    ///   - mediaService: The service providing model dimension rules.
    ///   - videoFrameListener: The callback receiving camera video frames.
    ///   - errorListener: The callback receiving capture runtime errors.
    @MainActor
    convenience init(
        rtcManager: any RtcManaging,
        mediaService: any MediaServicing = MediaService(),
        videoFrameListener: @escaping MediaVideoFrameListener,
        errorListener: @escaping XmaxErrorListener
    ) {
        self.init(
            rtcManager: rtcManager,
            permissionManager: PermissionManager(),
            mediaService: mediaService,
            captureManager: AgoraCameraCaptureManager(rtcManager: rtcManager),
            videoFrameListener: videoFrameListener,
            errorListener: errorListener
        )
    }

    /// Creates a camera controller with the specified dependencies.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC media adapter.
    ///   - permissionManager: The camera and microphone permission component.
    ///   - mediaService: The model dimension rules service.
    ///   - captureManager: The system video capture component.
    ///   - videoFrameListener: The callback receiving camera video frames.
    ///   - errorListener: The callback receiving capture runtime errors.
    init(
        rtcManager: any RtcManaging,
        permissionManager: any PermissionManaging,
        mediaService: any MediaServicing,
        captureManager: any CameraCaptureManaging,
        videoFrameListener: @escaping MediaVideoFrameListener = { _ in },
        errorListener: @escaping XmaxErrorListener = { _ in }
    ) {
        self.rtcManager = rtcManager
        self.permissionManager = permissionManager
        self.mediaService = mediaService
        self.captureManager = captureManager
        self.videoFrameListener = videoFrameListener
        self.errorListener = errorListener
    }

    /// Lists devices available for camera stream creation or switching.
    ///
    /// - Returns: The currently available camera devices.
    func listCameraDevices() -> [CameraDevice] {
        captureManager.listCameraDevices()
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
        let devices = captureManager.listCameraDevices()
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

    /// The active local camera video track, or nil before creation.
    var currentTrack: RealtimeVideoTrack? {
        stateLock.withLock { activeTrack }
    }

    /// Whether the current camera stream is configured to use the microphone.
    var useMicrophone: Bool {
        stateLock.withLock { activeTrack != nil && storedUseMicrophone }
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
    ///   - useMicrophone: Whether to request microphone permission and allow capture when realtime connects.
    ///
    /// - Returns: The media stream containing the local camera video track.
    ///
    /// - Throws: An error on an existing camera stream, invalid format, insufficient permissions, or capture startup
    ///   failure.
    func createLocalCameraStream(
        videoFormat: RealtimeVideoFormat,
        deviceID: String?,
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
            position: device.position,
            device: device
        )
        do {
            if useMicrophone {
                try await permissionManager.ensureMicrophonePermission()
            }
            try Task.checkCancellation()
            if !captureManager.suppliesRTCVideo {
                try rtcManager.useExternalVideoSource()
            }
            let preview = await makePreview(
                for: track,
                position: device.position
            )
            stateLock.withLock {
                activeTrack = track
                self.preview = preview
                storedUseMicrophone = useMicrophone
                isCaptureReady = false
                isPreviewAttached = false
            }
            captureManager.setNativePreviewReadyListener { [weak self] in
                guard let self else { return }
                let current = stateLock.withLock {
                    guard activeTrack === track else { return false }
                    isCaptureReady = true
                    return true
                }
                if current { notifyPreviewReady(for: track) }
            }
            try await captureManager.start(
                videoFormat: VideoFormat(
                    width: resolvedFormat.width,
                    height: resolvedFormat.height,
                    pixelFormat: .nv12
                ),
                frameRate: resolvedFormat.fps,
                deviceID: device.id,
                frameListener: { [weak self] frame in
                    try self?.handleFrame(
                        frame,
                        track: track,
                        preview: preview
                    )
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

    /// Starts audio capture for a microphone-enabled camera stream without local playback.
    ///
    /// - Throws: An error on RTC audio source configuration or microphone capture startup failure.
    func startMicrophoneCapture() throws {
        try audioOperationLock.withLock {
            let shouldStart = stateLock.withLock {
                guard activeTrack != nil, storedUseMicrophone, !isMicrophoneCapturing else { return false }
                // Retain stop-pending state after partial startup failure.
                isMicrophoneCapturing = true
                return true
            }
            guard shouldStart else { return }
            // Agora can wait for an in-flight camera callback; never hold its preview state lock here.
            try rtcManager.startAudioCapture()
        }
    }

    /// Stops microphone capture while retaining configuration for the next connection.
    ///
    /// - Throws: An error if stopping RTC microphone capture fails.
    func stopMicrophoneCapture() throws {
        try audioOperationLock.withLock {
            guard stateLock.withLock({ isMicrophoneCapturing }) else { return }
            try rtcManager.stopAudioCapture()
            stateLock.withLock { isMicrophoneCapturing = false }
        }
    }

    /// Stops camera and microphone capture and releases the track and local preview resources.
    func stopLocalCameraStream() async {
        do {
            try stopMicrophoneCapture()
        } catch {
            XmaxLogger.realtime.error(
                message: """
                    停止麦克风采集失败 (Failed to Stop Microphone Capture)
                    └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                    """
            )
        }
        let resources = stateLock.withLock {
            let resources = (activeTrack, preview)
            activeTrack = nil
            preview = nil
            previewReadyHandler = nil
            storedUseMicrophone = false
            isMicrophoneCapturing = false
            isCaptureReady = false
            isPreviewAttached = false
            return resources
        }
        await captureManager.stop()
        resources.1?.dispatcher?.reset()
        await MainActor.run {
            if let track = resources.0 { VideoRenderRegistry.unregister(track) }
            resources.1?.clear()
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
        try await captureManager.switchCamera(to: device.id)
        track.updateDevice(device)
        let preview = stateLock.withLock { self.preview }
        try await preview?.setMirrored(device.position == .front)
        return RealtimeMediaStream(
            id: StreamID.local.rawValue,
            videoTrack: track
        )
    }

}

private extension CameraController {

    /// Retains native rendering or the custom preview fallback.
    enum Preview: Sendable {

        /// A preview driven by decoded video frames.
        case decoded(DecodedVideoPreviewPresenter, DecodedVideoPreviewDispatcher)

        /// A preview rendered directly by the RTC engine.
        case native(RtcCameraPreviewPresenter)

        /// The decoded preview dispatcher, when decoded capture is in use.
        var dispatcher: DecodedVideoPreviewDispatcher? {
            if case .decoded(
                _,
                let dispatcher
            ) = self {
                return dispatcher
            }
            return nil
        }

        /// Attaches the active preview implementation to a video view.
        @MainActor func attach(
            to view: XmaxVideoView,
            contentMode: VideoContentMode
        ) throws {
            switch self {
            case .decoded(
                let presenter,
                _
            ):
                presenter.attach(
                    to: view,
                    contentMode: contentMode
                )
            case .native(let presenter):
                try presenter.attach(
                    to: view,
                    contentMode: contentMode
                )
            }
        }

        /// Removes the matching preview binding.
        @MainActor func detach(
            from view: XmaxVideoView
        ) throws {
            switch self {
            case .decoded(
                let presenter,
                _
            ): presenter.detach(from: view)
            case .native(let presenter): try presenter.detach(from: view)
            }
        }

        /// Updates mirroring for the active preview implementation.
        @MainActor func setMirrored(
            _ mirrored: Bool
        ) throws {
            switch self {
            case .decoded(
                let presenter,
                _
            ): presenter.setMirrored(mirrored)
            case .native(let presenter): try presenter.setMirrored(mirrored)
            }
        }

        /// Clears and releases the active preview presentation.
        @MainActor func clear() {
            switch self {
            case .decoded(
                let presenter,
                _
            ): presenter.clear()
            case .native(let presenter):
                do { try presenter.clear() } catch {
                    XmaxVideoView.logRenderingFailure(
                        title: "Failed to detach native camera preview",
                        error: error
                    )
                }
            }
        }
    }

    /// Creates and registers a preview binding for the camera track.
    ///
    /// - Parameters:
    ///   - track: The local camera track to preview.
    ///   - position: The camera position determining preview mirroring.
    ///
    /// - Returns: The preview components used for frame submission and resource release.
    @MainActor
    func makePreview(
        for track: RealtimeVideoTrack,
        position: CameraPosition
    ) -> Preview {
        let preview: Preview
        if captureManager.suppliesRTCVideo {
            preview = .native(
                RtcCameraPreviewPresenter(
                    rtcManager: rtcManager,
                    mirrored: position == .front
                )
            )
        } else {
            let presenter = DecodedVideoPreviewPresenter()
            presenter.setMirrored(position == .front)
            preview = .decoded(
                presenter,
                DecodedVideoPreviewDispatcher(presenter: presenter)
            )
        }
        VideoRenderRegistry.register(
            track,
            binding: VideoRenderBinding(
                attachHandler: { [weak self] view, contentMode in
                    guard let videoView = view as? XmaxVideoView else {
                        throw XmaxError(
                            code: .invalidConfiguration,
                            message: "Camera tracks require an XmaxVideoView"
                        )
                    }
                    try preview.attach(
                        to: videoView,
                        contentMode: contentMode
                    )
                    self?.stateLock.withLock { self?.isPreviewAttached = true }
                    self?.notifyPreviewReady(for: track)
                },
                detachHandler: { [weak self] view in
                    if let videoView = view as? XmaxVideoView { try preview.detach(from: videoView) }
                    self?.stateLock.withLock { self?.isPreviewAttached = false }
                }
            )
        )
        return preview
    }

    /// Submits captured frames for the current track to preview and media listeners.
    ///
    /// - Parameters:
    ///   - frame: The captured frame after orientation and dimension conversion.
    ///   - track: The camera track producing the frame.
    ///   - preview: The preview components retained by this track.
    ///
    /// - Throws: An error if the video frame listener fails to process the frame.
    func handleFrame(
        _ frame: VideoFrame,
        track: RealtimeVideoTrack,
        preview: Preview
    ) throws {
        let accepted = try stateLock.withLock {
            guard activeTrack === track else { return false }
            preview.dispatcher?.enqueue(frame)
            isCaptureReady = true
            // Native camera frames already enter Agora's encoder; the observer only feeds local preview.
            if !captureManager.suppliesRTCVideo { try videoFrameListener(frame) }
            return true
        }
        if accepted { notifyPreviewReady(for: track) }
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

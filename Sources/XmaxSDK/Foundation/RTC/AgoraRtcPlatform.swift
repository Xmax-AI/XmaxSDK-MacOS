//
//  AgoraRtcPlatform.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit
import Foundation
import AppKit

/// Adapts neutral engine operations to Agora calls.
final class AgoraRtcPlatform: RtcPlatform, AgoraRtcRoomPlatform, @unchecked Sendable {

    /// The initialized Agora engine.
    let engine: AgoraRtcEngineKit

    /// The native channel operations used by the room adapter.
    let roomEngine: any AgoraRtcRoomEngine

    /// The native camera operations used by the capture adapter.
    private let cameraEngine: any AgoraRtcCameraEngine

    /// Serializes room operations and shared configuration, separately from native camera calls.
    let lock = NSRecursiveLock()

    /// The lock serializing native camera configuration and preview operations.
    private let cameraControlLock = NSRecursiveLock()

    /// The lock protecting the publication source flag independently of engine calls.
    private let cameraStateLock = NSLock()

    /// The room owned by this platform instance.
    private weak var room: AgoraRtcRoom?

    /// The cached Agora external video frame.
    private let videoFrameCache = RtcVideoFrameCache()

    /// The most recently applied encoder configuration.
    private var videoConfiguration: VideoEncodingConfiguration?

    /// The upstream mirror mode retained independently of adaptive encoding dimensions.
    private var videoMirrorMode = AgoraVideoMirrorMode.disabled

    /// The observer forwarding remote pixels to the active room sink.
    private let videoObserver = RtcVideoFrameObserver()

    /// Whether the engine has accepted the remote frame observer.
    private var videoObserverRegistered = false

    /// The active native camera configuration under the camera control lock.
    private var cameraConfiguration: RtcCameraConfiguration?

    /// Whether publication uses the native camera track, protected by the camera state lock.
    private var storedUsesCameraTrack = false

    /// Whether local video publication selects the native camera track.
    var usesCameraTrack: Bool { cameraStateLock.withLock { storedUsesCameraTrack } }

    /// The native capture readiness and failure event sink.
    private let cameraEvents: RtcCameraEventSink

    /// The AppKit view currently bound to native camera rendering.
    @MainActor private weak var cameraPreviewView: NSView?

    /// Whether native preview capture has started.
    private var cameraPreviewStarted = false

    /// The external audio track identifier.
    private(set) var audioTrackID: Int?

    /// Wraps an Agora engine with the SDK platform interface.
    ///
    /// - Parameter engine: The initialized Agora engine.
    init(
        engine: AgoraRtcEngineKit,
        cameraEvents: RtcCameraEventSink,
        roomEngine: (any AgoraRtcRoomEngine)? = nil,
        cameraEngine: (any AgoraRtcCameraEngine)? = nil
    ) {
        self.engine = engine
        self.cameraEvents = cameraEvents
        self.roomEngine = roomEngine ?? engine
        self.cameraEngine = cameraEngine ?? engine
    }

    /// Creates an Agora engine with default camera and microphone capture disabled.
    ///
    /// - Parameter appID: The Agora application identifier.
    ///
    /// - Returns: The initialized platform adapter, or `nil` on configuration failure.
    static func create(
        appID: String
    ) -> (any RtcPlatform)? {
        let configuration = AgoraRtcEngineConfig()
        configuration.appId = appID
        configuration.channelProfile = .liveBroadcasting
        let cameraEvents = RtcCameraEventSink()
        let engine = AgoraRtcEngineKit.sharedEngine(
            with: configuration,
            delegate: cameraEvents
        )
        guard
            engine.enableVideo() == 0,
            engine.enableLocalVideo(false) == 0,
            engine.enableLocalAudio(false) == 0
        else {
            AgoraRtcEngineKit.destroy()
            return nil
        }
        return AgoraRtcPlatform(
            engine: engine,
            cameraEvents: cameraEvents
        )
    }

    /// Destroys the process-wide shared Agora engine.
    static func destroyEngine() {
        AgoraRtcEngineKit.destroy()
    }

    /// Applies upstream video encoding configuration.
    ///
    /// - Parameter configuration: Dimensions, frame rate, bitrate, and encoding preferences.
    ///
    /// - Throws: An error if the vendor engine rejects configuration.
    func configureVideoEncoding(
        _ configuration: VideoEncodingConfiguration
    ) throws {
        try lock.withLock {
            try applyVideoConfiguration(configuration)
            videoConfiguration = configuration
        }
    }

    /// Sets upstream mirroring through Agora's video encoder.
    ///
    /// - Parameter mirror: Whether to mirror the encoded camera stream.
    ///
    /// - Throws: An error if Agora rejects the encoder configuration.
    func configureLocalVideoMirror(
        _ mirror: Bool
    ) throws {
        try lock.withLock {
            let previous = videoMirrorMode
            videoMirrorMode = mirror ? .enabled : .disabled
            do { try reapplyVideoConfiguration() }
            catch {
                videoMirrorMode = previous
                throw error
            }
        }
    }

    /// Enables external video input without applying camera mirroring to caller-owned pixels.
    ///
    /// - Throws: An error if video source configuration fails.
    func useExternalVideoSource() throws {
        try cameraControlLock.withLock {
            guard cameraConfiguration == nil else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Stop native camera capture before using external video"
                )
            }
            try lock.withLock {
                videoFrameCache.removeAll()
                engine.setExternalVideoSource(
                    true,
                    useTexture: false,
                    sourceType: .videoFrame
                )
                videoMirrorMode = .disabled
                try reapplyVideoConfiguration()
                cameraStateLock.withLock { storedUsesCameraTrack = false }
            }
        }
    }

    /// Starts native camera capture and preview without waiting for an AppKit canvas.
    ///
    /// Throws if capture is already active, configuration is invalid, or a native engine operation fails.
    func startCameraCapture(
        configuration: RtcCameraConfiguration,
        previewReadyListener: @escaping @Sendable () -> Void,
        errorListener: @escaping XmaxErrorListener
    ) throws {
        try cameraControlLock.withLock {
            guard cameraConfiguration == nil, configuration.width > 0, configuration.height > 0,
                configuration.width.isMultiple(of: 2), configuration.height.isMultiple(of: 2),
                configuration.frameRate > 0, configuration.frameRate <= Int(Int32.max)
            else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Native camera capture configuration is invalid"
                )
            }
            cameraStateLock.withLock { storedUsesCameraTrack = true }
            cameraConfiguration = configuration
            cameraEvents.beginSession(
                ready: previewReadyListener,
                failure: errorListener
            )
            do {
                try Self.checkResult(
                    cameraEngine.enableLocalVideo(true),
                    operation: "enableLocalVideo"
                )
                try restartCameraCapture(configuration: configuration)
            } catch {
                try? stopCameraCapture()
                throw error
            }
        }
    }

    /// Reconfigures native capture while preserving the engine, device, and local canvas.
    ///
    /// Restores the preceding capture configuration if restart fails. A failed restoration reports
    /// a runtime camera failure so the lifecycle can release unusable media.
    func updateCameraCapture(
        videoFormat: VideoFormat,
        frameRate: Int
    ) throws {
        try cameraControlLock.withLock {
            guard let previous = cameraConfiguration else {
                throw XmaxError(
                    code: .mediaError,
                    message: "Native camera capture is not running"
                )
            }
            guard videoFormat.pixelFormat == .nv12,
                videoFormat.width.isMultiple(of: 2), videoFormat.height.isMultiple(of: 2),
                frameRate > 0, frameRate <= Int(Int32.max)
            else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Native camera capture configuration is invalid"
                )
            }
            let updated = RtcCameraConfiguration(
                deviceID: previous.deviceID,
                width: videoFormat.width,
                height: videoFormat.height,
                frameRate: frameRate
            )
            guard updated != previous else { return }
            do {
                // Agora applies capturer configuration at startup; retain the canvas during restart.
                cameraPreviewStarted = false
                let previewResult = cameraEngine.stopPreview(.camera)
                let captureResult = cameraEngine.stopCameraCapture(.camera)
                try Self.checkResult(
                    previewResult,
                    operation: "stopPreview"
                )
                try Self.checkResult(
                    captureResult,
                    operation: "stopCameraCapture"
                )
                try restartCameraCapture(configuration: updated)
                cameraConfiguration = updated
            } catch {
                let failure = error
                _ = cameraEngine.stopPreview(.camera)
                _ = cameraEngine.stopCameraCapture(.camera)
                do {
                    try restartCameraCapture(configuration: previous)
                } catch {
                    cameraEvents.reportFailure(XmaxError.from(error))
                }
                throw failure
            }
        }
    }

    /// Starts capture and preview without replacing readiness observation or the attached canvas.
    private func restartCameraCapture(
        configuration: RtcCameraConfiguration
    ) throws {
        let config = AgoraCameraCapturerConfiguration()
        config.deviceId = configuration.deviceID
        config.dimensions = CGSize(
            width: configuration.width,
            height: configuration.height
        )
        config.frameRate = Int32(configuration.frameRate)
        config.followEncodeDimensionRatio = true
        try Self.checkResult(
            cameraEngine.startCameraCapture(
                .camera,
                config: config
            ),
            operation: "startCameraCapture"
        )
        try Self.checkResult(
            cameraEngine.startPreview(.camera),
            operation: "startPreview"
        )
        cameraPreviewStarted = true
    }

    /// Switches the active native camera while preserving capture dimensions and frame rate.
    func switchCameraCapture(
        to deviceID: String
    ) throws {
        try cameraControlLock.withLock {
            guard let configuration = cameraConfiguration else {
                throw XmaxError(
                    code: .mediaError,
                    message: "Native camera capture is not running"
                )
            }
            try Self.checkResult(
                cameraEngine.setDevice(
                    .videoCapture,
                    deviceId: deviceID
                ),
                operation: "setVideoCaptureDevice"
            )
            cameraConfiguration = RtcCameraConfiguration(
                deviceID: deviceID,
                width: configuration.width,
                height: configuration.height,
                frameRate: configuration.frameRate
            )
        }
    }

    /// Invalidates camera callbacks and stops native preview and capture, preserving the first shutdown error.
    func stopCameraCapture() throws {
        try cameraControlLock.withLock {
            guard cameraConfiguration != nil else { return }
            // Disable callbacks before Agora shutdown, without retaining the room lock during SDK calls.
            cameraEvents.endSession()
            cameraConfiguration = nil
            cameraPreviewStarted = false
            var failure: (any Error)?
            for (result, operation) in [
                (cameraEngine.stopPreview(.camera), "stopPreview"),
                (cameraEngine.stopCameraCapture(.camera), "stopCameraCapture"),
                (cameraEngine.enableLocalVideo(false), "enableLocalVideo")
            ] {
                do {
                    try Self.checkResult(
                        result,
                        operation: operation
                    )
                } catch {
                    if failure == nil { failure = error }
                }
            }
            if let failure { throw failure }
        }
    }

    /// Binds the active camera to an AppKit canvas with the requested fitting and mirroring.
    @MainActor
    func attachCameraPreview(
        to view: NSView,
        contentMode: VideoContentMode,
        mirrored: Bool
    ) throws {
        try cameraControlLock.withLock {
            guard cameraConfiguration != nil else {
                throw XmaxError(
                    code: .mediaError,
                    message: "Native camera capture is not running"
                )
            }
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = 0
            canvas.sourceType = .camera
            canvas.view = view
            canvas.renderMode = contentMode == .fit ? .fit : .hidden
            canvas.mirrorMode = mirrored ? .enabled : .disabled
            try Self.checkResult(
                cameraEngine.setupLocalVideo(canvas),
                operation: "setupLocalVideo"
            )
            cameraPreviewView = view
            if !cameraPreviewStarted {
                try Self.checkResult(
                    cameraEngine.startPreview(.camera),
                    operation: "startPreview"
                )
                cameraPreviewStarted = true
            }
        }
    }

    /// Removes native rendering from the matching canvas without stopping capture.
    @MainActor
    func detachCameraPreview(
        from view: NSView
    ) throws {
        try cameraControlLock.withLock {
            guard cameraPreviewView === view else { return }
            cameraPreviewView = nil
            let canvas = AgoraRtcVideoCanvas()
            canvas.uid = 0
            canvas.sourceType = .camera
            canvas.view = nil
            try Self.checkResult(
                cameraEngine.setupLocalVideo(canvas),
                operation: "detachLocalVideo"
            )
        }
    }

    /// Replaces the remote pixel sink and returns whether required observer registration succeeds.
    func setRemoteVideoSink(
        _ sink: RtcRemoteVideoSink?
    ) -> Bool {
        lock.withLock {
            videoObserver.setRemote(sink)
            return sink == nil || registerVideoObserver()
        }
    }

    /// Registers the remote frame observer once and returns whether the engine accepts it.
    private func registerVideoObserver() -> Bool {
        guard !videoObserverRegistered else { return true }
        videoObserverRegistered = roomEngine.setVideoFrameDelegate(videoObserver)
        return videoObserverRegistered
    }

    /// Switches to microphone input and starts capture.
    ///
    /// - Throws: An error on audio source switching or capture failure.
    func startAudioCapture() throws {
        try lock.withLock {
            try stopExternalAudioSource()
            try Self.checkResult(
                engine.enableLocalAudio(true),
                operation: "enableLocalAudio"
            )
        }
    }

    /// Stops microphone capture.
    ///
    /// - Throws: An error if the vendor engine fails to stop capture.
    func stopAudioCapture() throws {
        try lock.withLock {
            try Self.checkResult(
                engine.enableLocalAudio(false),
                operation: "enableLocalAudio"
            )
        }
    }

    /// Enables external PCM input.
    ///
    /// - Throws: An error if external audio track creation fails.
    func startExternalAudioSource() throws {
        try lock.withLock {
            guard audioTrackID == nil else { return }
            try Self.checkResult(
                engine.enableLocalAudio(false),
                operation: "enableLocalAudio"
            )

            let config = AgoraAudioTrackConfig()
            config.enableLocalPlayback = false
            config.enableAudioProcessing = false
            let id = engine.createCustomAudioTrack(
                .direct,
                config: config
            )
            try Self.checkResult(
                id,
                operation: "createCustomAudioTrack"
            )
            audioTrackID = Int(id)
        }
    }

    /// Stops external PCM input and releases the audio track.
    ///
    /// - Throws: An error if audio track release fails.
    func stopExternalAudioSource() throws {
        try lock.withLock {
            guard let id = audioTrackID else { return }
            try Self.checkResult(
                engine.destroyCustomAudioTrack(id),
                operation: "destroyCustomAudioTrack"
            )
            audioTrackID = nil
        }
    }

    /// Pushes an external video frame.
    ///
    /// - Parameter frame: The SDK's neutral video frame.
    ///
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalVideoFrame(
        _ frame: VideoFrame
    ) throws {
        try lock.withLock {
            let converted = try videoFrameCache.frame(for: frame)
            _ = withExtendedLifetime(converted) {
                engine.pushExternalVideoFrame(
                    converted.value,
                    videoTrackId: 0
                )
            }
        }
    }

    /// Pushes an external audio frame.
    ///
    /// - Parameter frame: Timestamped 10 ms PCM data.
    ///
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalAudioFrame(
        _ frame: AudioFrame
    ) throws {
        let data = try RtcAudioConverter.convertFrame(frame)
        lock.withLock {
            guard let audioTrackID else { return }
            data.withUnsafeBytes { bytes in
                _ = engine.pushExternalAudioFrameRawData(
                    UnsafeMutableRawPointer(mutating: bytes.baseAddress!),
                    samples: AudioFrame.samplesPerFrame,
                    sampleRate: 48000,
                    channels: AudioFrame.channelCount,
                    trackId: audioTrackID,
                    timestamp: Double(frame.timestampUs) / 1000
                )
            }
        }
    }

    /// Creates an independent room adapter without initiating connection.
    ///
    /// - Parameter roomID: The server-assigned RTC room identifier.
    ///
    /// - Returns: The room before joining.
    ///
    /// - Throws: An error if an unreleased room already exists.
    func createRoom(
        roomID: String
    ) throws -> any RtcRoom {
        try lock.withLock {
            guard room == nil || room?.isClosed == true else {
                throw XmaxError(
                    code: .rtcError,
                    message: "RTC room is already active"
                )
            }
            let room = AgoraRtcRoom(
                platform: self,
                roomID: roomID
            )
            self.room = room
            return room
        }
    }

    /// Reapplies saved encoding configuration and the current upstream mirror mode.
    ///
    /// - Throws: An error if Agora rejects encoding configuration.
    func reapplyVideoConfiguration() throws {
        if let videoConfiguration {
            try applyVideoConfiguration(videoConfiguration)
        }
    }

    /// Converts negative Agora return codes to RTC errors.
    ///
    /// - Parameters:
    ///   - result: The platform call return code.
    ///   - operation: The operation name used in error descriptions.
    ///
    /// - Throws: An error if the return code is negative.
    static func checkResult<T: BinaryInteger>(
        _ result: T,
        operation: String
    ) throws {
        if result < 0 {
            throw XmaxError(
                code: .rtcError,
                message: "\(operation) failed: \(result)"
            )
        }
    }

    /// Applies encoding configuration to the active connection or global engine.
    ///
    /// - Parameter configuration: The video encoding configuration to apply.
    ///
    /// - Throws: An error if Agora encoding configuration fails.
    private func applyVideoConfiguration(
        _ configuration: VideoEncodingConfiguration
    ) throws {
        let rtcConfiguration = RtcVideoConverter.makeEncoderConfiguration(configuration)
        rtcConfiguration.mirrorMode = videoMirrorMode
        let result: Int32
        if let room, room.isJoined, !room.isClosed {
            result = cameraEngine.setVideoEncoderConfigurationEx(
                rtcConfiguration,
                connection: room.connection
            )
        } else {
            result = cameraEngine.setVideoEncoderConfiguration(rtcConfiguration)
        }
        try Self.checkResult(
            result,
            operation: "setVideoEncoderConfiguration"
        )
    }
}

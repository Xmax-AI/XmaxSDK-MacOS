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

/// Adapts neutral engine operations to Agora calls.
final class AgoraRtcPlatform: RtcPlatform, AgoraRtcRoomPlatform, @unchecked Sendable {

    /// The initialized Agora engine.
    let engine: AgoraRtcEngineKit

    /// The native channel operations used by the room adapter.
    let roomEngine: any AgoraRtcRoomEngine

    /// Applies video encoding configuration to the vendor engine.
    private let videoEncoder: any AgoraRtcVideoEncoder

    /// Serializes room operations and shared configuration.
    let lock = NSRecursiveLock()

    /// The room owned by this platform instance.
    private weak var room: AgoraRtcRoom?

    /// The most recently applied encoder configuration.
    private var videoConfiguration: VideoEncodingConfiguration?

    /// The upstream mirror mode retained across encoder reconfiguration.
    private var videoMirrorMode = AgoraVideoMirrorMode.disabled

    /// The observer forwarding remote pixels to the active room sink.
    private let videoObserver = RtcVideoFrameObserver()

    /// Whether the engine has accepted the remote frame observer.
    private var videoObserverRegistered = false

    /// The external audio track identifier.
    private(set) var audioTrackID: Int?

    /// Wraps an Agora engine with the SDK platform interface.
    ///
    /// - Parameters:
    ///   - engine: The initialized Agora engine.
    ///   - roomEngine: The room operations adapter; nil uses the native engine.
    ///   - videoEncoder: The encoding adapter; nil uses the native engine.
    init(
        engine: AgoraRtcEngineKit,
        roomEngine: (any AgoraRtcRoomEngine)? = nil,
        videoEncoder: (any AgoraRtcVideoEncoder)? = nil
    ) {
        self.engine = engine
        self.roomEngine = roomEngine ?? engine
        self.videoEncoder = videoEncoder ?? engine
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
        let engine = AgoraRtcEngineKit.sharedEngine(
            with: configuration,
            delegate: nil
        )
        guard
            engine.enableVideo() == 0,
            engine.enableLocalVideo(false) == 0,
            engine.enableLocalAudio(false) == 0
        else {
            AgoraRtcEngineKit.destroy()
            return nil
        }
        return AgoraRtcPlatform(engine: engine)
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
    func useExternalVideoSource(
        useTexture: Bool
    ) throws {
        try lock.withLock {
            engine.setExternalVideoSource(
                true,
                useTexture: useTexture,
                sourceType: .videoFrame
            )
            videoMirrorMode = .disabled
            try reapplyVideoConfiguration()
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
            let converted = try RtcVideoConverter.convertFrame(frame)
            // AgoraVideoFrame.textureBuf does not retain the pixel buffer.
            _ = withExtendedLifetime(frame) {
                engine.pushExternalVideoFrame(
                    converted,
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
            result = videoEncoder.setVideoEncoderConfigurationEx(
                rtcConfiguration,
                connection: room.connection
            )
        } else {
            result = videoEncoder.setVideoEncoderConfiguration(rtcConfiguration)
        }
        try Self.checkResult(
            result,
            operation: "setVideoEncoderConfiguration"
        )
    }
}

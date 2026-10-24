//
//  AgoraRtcPlatform.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit
import Foundation

/// Adapts neutral engine operations to Agora calls.
final class AgoraRtcPlatform: RtcPlatform, AgoraRtcRoomPlatform, @unchecked Sendable {

    /// Platform resources
    let engine: AgoraRtcEngineKit
    var roomEngine: any AgoraRtcRoomEngine { engine }
    /// Serializes engine operations. Agora callback threads must use their independent state lock.
    let lock = NSRecursiveLock()
    private weak var room: AgoraRtcRoom?

    /// Video configuration
    private let videoFrameCache = RtcVideoFrameCache()
    private var videoConfiguration: VideoEncodingConfiguration?

    /// Audio resources
    private(set) var audioTrackID: Int?

    /// Wraps an Agora engine with the SDK platform interface.
    ///
    /// - Parameter engine: The initialized Agora engine.
    private init(engine: AgoraRtcEngineKit) {
        self.engine = engine
    }

    /// Creates an Agora engine with default camera and microphone capture disabled.
    ///
    /// - Parameter appID: The Agora application identifier.
    /// - Returns: The initialized platform adapter, or `nil` on configuration failure.
    static func create(appID: String) -> (any RtcPlatform)? {
        let configuration = AgoraRtcEngineConfig()
        configuration.appId = appID
        configuration.channelProfile = .liveBroadcasting
        let engine = AgoraRtcEngineKit.sharedEngine(with: configuration, delegate: nil)
        guard engine.enableVideo() == 0,
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
    /// - Throws: An error if the vendor engine rejects configuration.
    func configureVideoEncoding(_ configuration: VideoEncodingConfiguration) throws {
        try lock.withLock {
            try applyVideoConfiguration(configuration)
            videoConfiguration = configuration
        }
    }

    /// Enables external video input.
    ///
    /// - Throws: An error if video source configuration fails.
    func useExternalVideoSource() throws {
        try lock.withLock {
            videoFrameCache.removeAll()
            engine.setExternalVideoSource(true, useTexture: false, sourceType: .videoFrame)
            try reapplyVideoConfiguration()
        }
    }

    /// Switches to microphone input and starts capture.
    ///
    /// - Throws: An error on audio source switching or capture failure.
    func startAudioCapture() throws {
        try lock.withLock {
            try stopExternalAudioSource()
            try Self.checkResult(engine.enableLocalAudio(true), operation: "enableLocalAudio")
        }
    }

    /// Stops microphone capture.
    ///
    /// - Throws: An error if the vendor engine fails to stop capture.
    func stopAudioCapture() throws {
        try lock.withLock {
            try Self.checkResult(engine.enableLocalAudio(false), operation: "enableLocalAudio")
        }
    }

    /// Enables external PCM input.
    ///
    /// - Throws: An error if external audio track creation fails.
    func startExternalAudioSource() throws {
        try lock.withLock {
            guard audioTrackID == nil else { return }
            try Self.checkResult(engine.enableLocalAudio(false), operation: "enableLocalAudio")

            let config = AgoraAudioTrackConfig()
            config.enableLocalPlayback = false
            config.enableAudioProcessing = false
            let id = engine.createCustomAudioTrack(.direct, config: config)
            try Self.checkResult(id, operation: "createCustomAudioTrack")
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
                engine.destroyCustomAudioTrack(id), operation: "destroyCustomAudioTrack")
            audioTrackID = nil
        }
    }

    /// Pushes an external video frame.
    ///
    /// - Parameter frame: The SDK's neutral video frame.
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalVideoFrame(_ frame: VideoFrame) throws {
        try lock.withLock {
            let converted = try videoFrameCache.frame(for: frame)
            _ = withExtendedLifetime(converted) {
                engine.pushExternalVideoFrame(converted.value, videoTrackId: 0)
            }
        }
    }

    /// Pushes an external audio frame.
    ///
    /// - Parameter frame: Timestamped 10 ms PCM data.
    /// - Throws: An error if frame format or data is invalid.
    func pushExternalAudioFrame(_ frame: AudioFrame) throws {
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
    /// - Returns: The room before joining.
    /// - Throws: An error if an unreleased room already exists.
    func createRoom(roomID: String) throws -> any RtcRoom {
        try lock.withLock {
            guard room == nil || room?.isClosed == true else {
                throw XmaxError(code: .rtcError, message: "RTC room is already active")
            }
            let room = AgoraRtcRoom(platform: self, roomID: roomID)
            self.room = room
            return room
        }
    }

    /// Reapplies saved encoding configuration with upstream mirroring disabled.
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
    /// - Throws: An error if the return code is negative.
    static func checkResult<T: BinaryInteger>(_ result: T, operation: String) throws {
        if result < 0 {
            throw XmaxError(code: .rtcError, message: "\(operation) failed: \(result)")
        }
    }

    /// Applies encoding configuration to the active connection or global engine.
    ///
    /// - Parameter configuration: The video encoding configuration to apply.
    /// - Throws: An error if Agora encoding configuration fails.
    private func applyVideoConfiguration(_ configuration: VideoEncodingConfiguration) throws {
        let rtcConfiguration = RtcVideoConverter.makeEncoderConfiguration(configuration)
        let result: Int32
        if let room, room.isJoined, !room.isClosed {
            result = engine.setVideoEncoderConfigurationEx(
                rtcConfiguration, connection: room.connection)
        } else {
            result = engine.setVideoEncoderConfiguration(rtcConfiguration)
        }
        try Self.checkResult(result, operation: "setVideoEncoderConfiguration")
    }
}

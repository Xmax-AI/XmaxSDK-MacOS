//
//  RtcPlatformStub.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import AppKit

@testable import XmaxSDK

/// An RTC stub that does not create a vendor engine.
final class RtcPlatformStub: RtcPlatform, @unchecked Sendable {

    /// Room factory
    private let makeRoom: @Sendable (String) throws -> any RtcRoom
    private let onPreviewAttach: @MainActor @Sendable (NSView) -> Void
    private let onAudioCapture: @Sendable (String?) throws -> Void
    private let onMicrophoneDevice: @Sendable (String?) throws -> Void
    private let onAudioStop: @Sendable () throws -> Void
    private let audioLock = NSLock()
    private var storedMicrophoneLevelListener: RtcMicrophoneLevelListener?
    private var audioCaptures = 0
    private var audioStops = 0

    var microphoneLevelListener: RtcMicrophoneLevelListener? { audioLock.withLock { storedMicrophoneLevelListener } }
    var audioCaptureCount: Int { audioLock.withLock { audioCaptures } }
    var audioStopCount: Int { audioLock.withLock { audioStops } }

    init(makeRoom: @escaping @Sendable (String) throws -> any RtcRoom = { _ in RtcRoomStub() },
         onPreviewAttach: @escaping @MainActor @Sendable (NSView) -> Void = { _ in },
         onAudioCapture: @escaping @Sendable (String?) throws -> Void = { _ in },
         onMicrophoneDevice: @escaping @Sendable (String?) throws -> Void = { _ in },
         onAudioStop: @escaping @Sendable () throws -> Void = {}) {
        self.makeRoom = makeRoom
        self.onPreviewAttach = onPreviewAttach
        self.onAudioCapture = onAudioCapture
        self.onMicrophoneDevice = onMicrophoneDevice
        self.onAudioStop = onAudioStop
    }

    func configureVideoEncoding(_ configuration: VideoEncodingConfiguration) throws {}
    func configureLocalVideoMirror(_ mirror: Bool) throws {}
    func useExternalVideoSource() throws {}
    func startCameraCapture(
        configuration: RtcCameraConfiguration,
        previewReadyListener: @escaping @Sendable () -> Void,
        errorListener: @escaping XmaxErrorListener
    ) throws {}
    func switchCameraCapture(to deviceID: String) throws {}
    func updateCameraCapture(videoFormat: VideoFormat, frameRate: Int) throws {}
    func stopCameraCapture() throws {}
    @MainActor func attachCameraPreview(to view: NSView, contentMode: VideoContentMode, mirrored: Bool) throws { onPreviewAttach(view) }
    @MainActor func detachCameraPreview(from view: NSView) throws {}
    func startAudioCapture(deviceID: String?) throws {
        audioLock.withLock { audioCaptures += 1 }
        try onAudioCapture(deviceID)
    }
    func setMicrophoneDevice(_ deviceID: String?) throws { try onMicrophoneDevice(deviceID) }
    func setMicrophoneLevelListener(_ listener: RtcMicrophoneLevelListener?) {
        audioLock.withLock { storedMicrophoneLevelListener = listener }
    }
    func stopAudioCapture() throws {
        audioLock.withLock { audioStops += 1 }
        try onAudioStop()
    }
    func startExternalAudioSource() throws {}
    func stopExternalAudioSource() throws {}
    func pushExternalVideoFrame(_ frame: VideoFrame) throws {}
    func pushExternalAudioFrame(_ frame: AudioFrame) throws {}

    func createRoom(roomID: String) throws -> any RtcRoom {
        try makeRoom(roomID)
    }
}

final class RtcRoomStub: RtcRoom, @unchecked Sendable {

    /// Controllable operations
    private let onJoin: @Sendable () throws -> Void

    /// Listeners and call records
    private let lock = NSLock()
    private var listener: (@Sendable (RtcRoomEvent) -> Void)?
    private var lastListener: (@Sendable (RtcRoomEvent) -> Void)?
    private var frameListener: RtcRemoteVideoFrameListener?
    private var audioFrameListener: RtcRemoteAudioFrameListener?
    private var destructions = 0
    private var sentMessages: [String] = []
    private var videoPublications: [Bool] = []
    private var joinedConfigurations: [RoomJoinConfiguration] = []

    var destroyCount: Int { lock.withLock { destructions } }
    var messages: [String] { lock.withLock { sentMessages } }
    var publishedVideo: [Bool] { lock.withLock { videoPublications } }
    var configurations: [RoomJoinConfiguration] { lock.withLock { joinedConfigurations } }

    init(
        onJoin: @escaping @Sendable () throws -> Void = {}
    ) {
        self.onJoin = onJoin
    }

    func setEventListener(_ listener: (@Sendable (RtcRoomEvent) -> Void)?) {
        lock.withLock {
            self.listener = listener
            if let listener { lastListener = listener }
        }
    }

    func join(configuration: RoomJoinConfiguration) throws {
        lock.withLock { joinedConfigurations.append(configuration) }
        try onJoin()
    }

    func destroy() {
        lock.withLock {
            destructions += 1
            listener = nil
        }
    }

    func emit(_ event: RtcRoomEvent, late: Bool = false) {
        let callback = lock.withLock { late ? lastListener : listener }
        callback?(event)
    }

    func publishLocalVideo(_ publish: Bool) throws {
        lock.withLock { videoPublications.append(publish) }
    }

    func publishLocalAudio(_ publish: Bool) throws {}
    func subscribeRemoteVideo(userID: String, subscribe: Bool) throws {}
    func subscribeRemoteAudio(userID: String, subscribe: Bool) throws {}
    func setRemoteAudioVolume(_ volume: Int, for userID: String) throws {}

    func setRemoteVideoFrameListener(_ listener: RtcRemoteVideoFrameListener?, for userID: String)
        throws
    {
        lock.withLock { frameListener = listener }
    }

    func setRemoteAudioFrameListener(_ listener: RtcRemoteAudioFrameListener?, for userID: String) throws {
        lock.withLock { audioFrameListener = listener }
    }

    func emitAudioFrame(_ frame: RtcRemoteAudioFrame) {
        let callback = lock.withLock { audioFrameListener }
        callback?(frame)
    }

    func emitFrame(_ frame: RealtimeVideoFrame) {
        let callback = lock.withLock { frameListener }
        callback?(frame)
    }

    @discardableResult
    func sendRoomMessage(_ message: String, reportFailure: Bool = true, replacingPendingMessage key: String? = nil) throws -> Task<Void, any Error> {
        lock.withLock { sentMessages.append(message) }
        return Task {}
    }

    func discardPendingMessages(key: String?) {}
}

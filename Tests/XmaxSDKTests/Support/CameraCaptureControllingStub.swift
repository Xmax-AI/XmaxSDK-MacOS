//
//  CameraCaptureControllingStub.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@testable import XmaxSDK

final class CameraCaptureControllingStub: CameraCaptureControlling, @unchecked Sendable {

    enum Call: Equatable {
        case start(String)
        case switchCamera(String)
        case updateFormat(VideoFormat, Int)
        case stop
    }

    /// Test configuration
    let devices: [CameraDevice]
    let startError: (any Error)?
    var updateError: (any Error)?
    var updateHandler: (@Sendable () async -> Void)?
    let switchError: (any Error)?
    let startHandler: (@Sendable () async -> Void)?
    let automaticallyReady: Bool

    /// Call records
    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var previewReadyListener: (@Sendable () -> Void)?
    private var videoFrameListener: MediaVideoFrameListener?

    init(
        devices: [CameraDevice],
        startError: (any Error)? = nil,
        switchError: (any Error)? = nil,
        startHandler: (@Sendable () async -> Void)? = nil,
        automaticallyReady: Bool = false
    ) {
        self.devices = devices
        self.startError = startError
        self.switchError = switchError
        self.startHandler = startHandler
        self.automaticallyReady = automaticallyReady
    }

    var calls: [Call] { lock.withLock { recordedCalls } }

    var currentPreviewReadyListener: (@Sendable () -> Void)? {
        lock.withLock { previewReadyListener }
    }

    func listCameraDevices() -> [CameraDevice] { devices }

    func start(
        videoFormat: VideoFormat,
        frameRate: Int,
        deviceID: String,
        frameListener: @escaping MediaVideoFrameListener,
        previewReadyListener: @escaping @Sendable () -> Void,
        errorListener: @escaping XmaxErrorListener
    ) async throws {
        lock.withLock {
            recordedCalls.append(.start(deviceID))
            self.previewReadyListener = previewReadyListener
            videoFrameListener = frameListener
        }
        if let startError { throw startError }
        await startHandler?()
        if automaticallyReady { previewReadyListener() }
    }

    func switchCamera(to deviceID: String) async throws {
        lock.withLock { recordedCalls.append(.switchCamera(deviceID)) }
        if let switchError { throw switchError }
    }

    func updateFormat(_ videoFormat: VideoFormat, frameRate: Int) async throws {
        lock.withLock { recordedCalls.append(.updateFormat(videoFormat, frameRate)) }
        await updateHandler?()
        if let updateError { throw updateError }
    }

    func stop() async {
        lock.withLock {
            recordedCalls.append(.stop)
            previewReadyListener = nil
            videoFrameListener = nil
        }
    }

    func emitVideo(_ frame: VideoFrame) throws {
        try lock.withLock { videoFrameListener }?(frame)
    }
}

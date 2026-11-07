//
//  MicrophoneCaptureControllingStub.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@testable import XmaxSDK

final class MicrophoneCaptureControllingStub: MicrophoneCaptureControlling, @unchecked Sendable {

    enum Call: Equatable {
        case select(String?)
        case start
        case stop
    }

    private let lock = NSLock()
    private let selectionError: (any Error)?
    private var recordedCalls: [Call] = []
    private var frameListener: MediaAudioFrameListener?
    @MainActor private var levelListener: RealtimeMicrophoneLevelListener?

    var calls: [Call] { lock.withLock { recordedCalls } }

    init(selectionError: (any Error)? = nil) {
        self.selectionError = selectionError
    }

    func selectDevice(_ deviceID: String?) throws {
        lock.withLock { recordedCalls.append(.select(deviceID)) }
        if let selectionError { throw selectionError }
    }

    func start(frameListener: @escaping MediaAudioFrameListener) throws {
        lock.withLock {
            recordedCalls.append(.start)
            self.frameListener = frameListener
        }
    }

    func stop() {
        lock.withLock {
            recordedCalls.append(.stop)
            frameListener = nil
        }
    }

    @MainActor
    func setLevelListener(_ listener: RealtimeMicrophoneLevelListener?) {
        levelListener = listener
        listener?(nil)
    }

    @MainActor
    func emitLevel(_ level: Float?) {
        levelListener?(level)
    }

    func emitAudio(_ frame: AudioFrame) throws {
        try lock.withLock { frameListener }?(frame)
    }
}

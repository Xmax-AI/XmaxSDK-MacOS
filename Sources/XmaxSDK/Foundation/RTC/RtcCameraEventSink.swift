//
//  RtcCameraEventSink.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit
import Foundation

/// Receives native camera readiness and microphone metadata independently of raw media frame observation.
/// Camera events use a serial queue; the microphone monitor owns application level delivery.
final class RtcCameraEventSink: NSObject, AgoraRtcEngineDelegate, @unchecked Sendable {

    /// Readiness, failure, and first-frame delivery state for one native camera startup.
    private struct Session {

        /// The identity used to reject callbacks from earlier camera startups.
        let id = UUID()

        /// The callback receiving usable native capture readiness.
        let ready: @Sendable () -> Void

        /// The callback receiving the first native capture failure.
        let failure: XmaxErrorListener

        /// Whether the first native preview frame has been observed.
        var didDisplay = false

        /// Whether capture readiness has already been reported.
        var didBecomeReady = false

        /// Whether capture has already reported a failure.
        var didFail = false
    }

    /// The lock protecting camera callback state.
    private let lock = NSLock()

    /// The serial queue delivering camera callbacks outside native engine callbacks.
    private let queue = DispatchQueue(label: "ai.xmax.sdk.camera-events")

    /// The current camera startup callbacks and delivery flags.
    private var session: Session?

    /// The physical microphone observer; input lifecycle and stale-source checks belong to RtcManager.
    private var microphoneLevelListener: RtcMicrophoneLevelListener?

    /// Whether native microphone readings remain valid after the most recent audio state event.
    private var microphoneInputAvailable = true

    /// Replaces the microphone metadata receiver independently of camera preview readiness.
    func setMicrophoneLevelListener(
        _ listener: RtcMicrophoneLevelListener?
    ) {
        lock.withLock {
            microphoneLevelListener = listener
        }
    }

    /// Forwards only the local input entry, excluding remote speaker and mixed playback totals.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        reportAudioVolumeIndicationOfSpeakers speakers: [AgoraRtcAudioVolumeInfo],
        totalVolume: Int
    ) {
        guard let local = speakers.first(where: { $0.uid == 0 }) else { return }
        receiveMicrophoneEvent(.level(min(1, Float(local.volume) / 255)))
    }

    /// Clears the input reading when native capture stops or fails, without stopping video.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        localAudioStateChanged state: AgoraAudioLocalState,
        reason: AgoraAudioLocalReason
    ) {
        let unavailable = state == .stopped || state == .failed
        receiveMicrophoneEvent(.availability(!unavailable))
    }

    /// Shares microphone validity between global-engine and connection-specific native callbacks.
    func receiveMicrophoneEvent(
        _ event: RtcMicrophoneEvent
    ) {
        switch event {
        case .level(let level):
            let callback = lock.withLock { microphoneInputAvailable ? microphoneLevelListener : nil }
            callback?(level)
        case .availability(let available):
            let callback = lock.withLock {
                microphoneInputAvailable = available
                return microphoneLevelListener
            }
            if !available { callback?(nil) }
        }
    }

    /// Installs a new callback session, invalidating callbacks from earlier startups.
    func beginSession(
        ready: @escaping @Sendable () -> Void,
        failure: @escaping XmaxErrorListener
    ) {
        lock.withLock {
            session = Session(
                ready: ready,
                failure: failure
            )
        }
    }

    /// Invalidates camera callbacks from the current startup.
    func endSession() {
        lock.withLock {
            session = nil
        }
    }

    /// Handles native camera progress or failure without waiting for engine operation locks.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        firstLocalVideoFrameWith size: CGSize,
        elapsed: Int,
        sourceType: AgoraVideoSourceType
    ) {
        guard sourceType == .camera, size.width > 0, size.height > 0 else { return }
        let delivery = lock.withLock { () -> (session: Session, reportReady: Bool)? in
            guard var current = session, !current.didDisplay, !current.didFail else { return nil }
            let reportReady = !current.didBecomeReady
            current.didDisplay = true
            current.didBecomeReady = true
            session = current
            return (current, reportReady)
        }
        guard let delivery else { return }
        if delivery.reportReady { deliverReady(delivery.session) }
    }

    /// Handles native camera progress or failure without waiting for engine operation locks.
    func rtcEngine(
        _ engine: AgoraRtcEngineKit,
        localVideoStateChangedOf state: AgoraVideoLocalState,
        reason: AgoraLocalVideoStreamReason,
        sourceType: AgoraVideoSourceType
    ) {
        guard sourceType == .camera else { return }
        if state == .capturing || state == .encoding {
            let delivery = lock.withLock { () -> Session? in
                guard var current = session, !current.didBecomeReady, !current.didFail else { return nil }
                current.didBecomeReady = true
                session = current
                return current
            }
            if let delivery { deliverReady(delivery) }
            return
        }
        guard state == .failed else { return }
        reportFailure(
            XmaxError(
                code: .mediaError,
                message: "Agora camera capture failed (reason: \(reason.rawValue))"
            )
        )
    }

    /// Reports the first failure for the current camera session outside engine control locks.
    func reportFailure(
        _ error: XmaxError
    ) {
        let delivery = lock.withLock { () -> Session? in
            guard var current = session, !current.didFail else { return nil }
            current.didFail = true
            session = current
            return current
        }
        guard let delivery else { return }
        queue.async { [weak self] in
            guard self?.isCurrent(delivery.id) == true else { return }
            delivery.failure(error)
        }
    }

    /// Checks whether a queued callback still belongs to the current camera session.
    private func isCurrent(
        _ id: UUID
    ) -> Bool { lock.withLock { session?.id == id } }

    /// Delivers readiness only while the camera session remains current and has not failed.
    private func deliverReady(
        _ delivery: Session
    ) {
        queue.async { [weak self] in
            guard let self, lock.withLock({ session?.id == delivery.id && session?.didFail == false }) else { return }
            delivery.ready()
        }
    }
}

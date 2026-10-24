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

/// Native rendering metadata is independent of the raw video frame observer.
/// Vendor callbacks return immediately; application callbacks use a separate serial queue.
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
        let delivery = lock.withLock { () -> Session? in
            guard var current = session, !current.didFail else { return nil }
            current.didFail = true
            session = current
            return current
        }
        guard let delivery else { return }
        let failure = XmaxError(
            code: .mediaError,
            message: "Agora camera capture failed (reason: \(reason.rawValue))"
        )
        queue.async { [weak self] in
            guard self?.isCurrent(delivery.id) == true else { return }
            delivery.failure(failure)
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

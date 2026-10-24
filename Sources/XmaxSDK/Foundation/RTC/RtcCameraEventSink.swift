@preconcurrency import AgoraRtcKit
import Foundation

/// Native rendering metadata is independent of the raw video frame observer.
/// Vendor callbacks return immediately; application callbacks use a separate serial queue.
final class RtcCameraEventSink: NSObject, AgoraRtcEngineDelegate, @unchecked Sendable {
    private struct Session {
        let id = UUID()
        let ready: @Sendable () -> Void
        let failure: XmaxErrorListener
        let firstFrameTiming: LocalMediaPreparationTiming.Span?
        var didDisplay = false
        var didBecomeReady = false
        var didFail = false
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.xmax.sdk.camera-events")
    private var session: Session?

    func beginSession(ready: @escaping @Sendable () -> Void, failure: @escaping XmaxErrorListener) {
        let next = Session(ready: ready, failure: failure,
                           firstFrameTiming: LocalMediaPreparationTiming.current?.begin(.firstNativePreviewFrame))
        let previous = lock.withLock {
            let previous = session
            session = next
            return previous
        }
        previous?.firstFrameTiming?.finish(.cancelled)
    }

    func endSession() {
        let previous = lock.withLock {
            let previous = session
            session = nil
            return previous
        }
        previous?.firstFrameTiming?.finish(.cancelled)
    }

    func rtcEngine(
        _ engine: AgoraRtcEngineKit, firstLocalVideoFrameWith size: CGSize,
        elapsed: Int, sourceType: AgoraVideoSourceType
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
        delivery.session.firstFrameTiming?.finish()
        if delivery.reportReady { deliverReady(delivery.session) }
    }

    func rtcEngine(
        _ engine: AgoraRtcEngineKit, localVideoStateChangedOf state: AgoraVideoLocalState,
        reason: AgoraLocalVideoStreamReason, sourceType: AgoraVideoSourceType
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
        delivery.firstFrameTiming?.finish(.failed)
        let failure = XmaxError(code: .mediaError, message: "Agora camera capture failed (reason: \(reason.rawValue))")
        queue.async { [weak self] in
            guard self?.isCurrent(delivery.id) == true else { return }
            delivery.failure(failure)
        }
    }

    private func isCurrent(_ id: UUID) -> Bool { lock.withLock { session?.id == id } }

    private func deliverReady(_ delivery: Session) {
        queue.async { [weak self] in
            guard let self, lock.withLock({ session?.id == delivery.id && session?.didFail == false }) else { return }
            delivery.ready()
        }
    }
}

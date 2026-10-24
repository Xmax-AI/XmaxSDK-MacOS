import Foundation

/// Nested diagnostic spans for local camera preparation; does not change generation timing or media behavior.
enum LocalMediaPreparationTiming {
    @TaskLocal static var current: Trace?

    enum Stage: String, Sendable {
        case total = "media.total"
        case mediaPrepare = "media.prepare"
        case engineAcquire = "engine.acquire"
        case engineCreate = "engine.create"
        case sharedEngine = "agora.sharedEngine"
        case enableVideo = "agora.enableVideo"
        case disableLocalVideo = "agora.disableLocalVideo"
        case disableLocalAudio = "agora.disableLocalAudio"
        case resolveFormat = "camera.resolveFormat"
        case cameraPermission = "camera.permission"
        case microphonePermission = "camera.microphonePermission"
        case resolveDevice = "camera.resolveDevice"
        case externalVideoSource = "camera.externalVideoSource"
        case createPreview = "camera.createPreview"
        case captureStart = "camera.captureStart"
        case captureQueueWait = "capture.queueWait"
        case captureBeginConfiguration = "capture.beginConfiguration"
        case captureInputSetup = "capture.inputSetup"
        case captureDeviceDiscovery = "capture.deviceDiscovery"
        case captureFormatSelection = "capture.formatSelection"
        case captureInputCreate = "capture.inputCreate"
        case captureDeviceConfiguration = "capture.deviceConfiguration"
        case captureOutputSetup = "capture.outputSetup"
        case captureCommitConfiguration = "capture.commitConfiguration"
        case captureStartRunning = "capture.startRunning"
        case firstCapturedFrame = "capture.firstDeliveredFrame"
        case interpolationConfiguration = "media.interpolationConfiguration"
        case previewReadinessRegistration = "media.previewReadinessRegistration"
        case rtcRoomJoin = "rtc.roomJoinAndCallback"
        case rtcJoinCall = "rtc.roomJoinCall"
        case agoraJoinCall = "agora.joinChannelEx"
        case registerVideoObserver = "agora.registerVideoObserver"
        case enableNativeCamera = "agora.enableLocalVideo"
        case startNativeCamera = "agora.startCameraCapture"
        case startNativePreview = "agora.startPreview"
        case attachNativePreview = "agora.setupLocalVideo"
        case firstNativePreviewFrame = "camera.firstPreviewFrame"
    }

    enum Outcome: String, Sendable { case completed, failed, cancelled }

    struct Record: Sendable {
        let traceID: UUID
        let stage: Stage
        let outcome: Outcome?
        let offsetMs: Double
        let durationMs: Double?

        var message: String {
            let duration = durationMs.map { String(format: " duration=%.3f ms", $0) } ?? ""
            return "Local media preparation [\(traceID)] stage=\(stage.rawValue) event=\(outcome?.rawValue ?? "started")" +
                String(format: " offset=%.3f ms", offsetMs) + duration
        }
    }

    final class Trace: Sendable {
        let id: UUID
        private let origin: UInt64
        fileprivate let now: @Sendable () -> UInt64
        private let emit: @Sendable (Record) -> Void

        init(
            id: UUID = UUID(),
            now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            emit: @escaping @Sendable (Record) -> Void = {
                XmaxLogger.media.info(message: $0.message, option: .performance)
            }
        ) {
            self.id = id
            self.now = now
            self.emit = emit
            origin = now()
        }

        func begin(_ stage: Stage) -> Span {
            let startedAt = now()
            record(stage, outcome: nil, at: startedAt, duration: nil)
            return Span(trace: self, stage: stage, startedAt: startedAt)
        }

        fileprivate func record(_ stage: Stage, outcome: Outcome?, at time: UInt64, duration: UInt64?) {
            emit(Record(traceID: id, stage: stage, outcome: outcome,
                        offsetMs: Double(time >= origin ? time - origin : 0) / 1_000_000,
                        durationMs: duration.map { Double($0) / 1_000_000 }))
        }
    }

    /// Retains its trace across dispatch queues and can finish only once, including during cancellation.
    final class Span: @unchecked Sendable {
        private let trace: Trace
        private let stage: Stage
        private let startedAt: UInt64
        private let lock = NSLock()
        private var finished = false

        fileprivate init(trace: Trace, stage: Stage, startedAt: UInt64) {
            self.trace = trace
            self.stage = stage
            self.startedAt = startedAt
        }

        @discardableResult
        func finish(_ outcome: Outcome = .completed) -> Bool {
            let shouldFinish = lock.withLock {
                guard !finished else { return false }
                finished = true
                return true
            }
            guard shouldFinish else { return false }
            let endedAt = trace.now()
            trace.record(stage, outcome: outcome, at: endedAt,
                         duration: endedAt >= startedAt ? endedAt - startedAt : 0)
            return true
        }
    }

    static func measure<T>(_ stage: Stage, _ operation: () throws -> T) rethrows -> T {
        let span = current?.begin(stage)
        do {
            let result = try operation()
            span?.finish()
            return result
        } catch {
            span?.finish(outcome(for: error))
            throw error
        }
    }

    static func measureAsync<T>(
        _ stage: Stage, isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let span = current?.begin(stage)
        do {
            let result = try await operation()
            span?.finish()
            return result
        } catch {
            span?.finish(outcome(for: error))
            throw error
        }
    }

    private static func outcome(for error: any Error) -> Outcome {
        error is CancellationError || (error as? XmaxError)?.code == .cancelled ? .cancelled : .failed
    }
}

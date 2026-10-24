//
//  LocalMediaPreparationTiming.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Diagnostic spans for local camera preparation, independent of generation stage timing.
enum LocalMediaPreparationTiming {

    /// The camera preparation trace inherited by child tasks.
    @TaskLocal static var current: Trace?

    /// A measured operation within camera preparation or RTC setup.
    enum Stage: String, Sendable {

        /// The complete local media preparation flow.
        case total = "media.total"

        /// The local media preparation operation.
        case mediaPrepare = "media.prepare"

        /// The wait for exclusive RTC engine ownership.
        case engineAcquire = "engine.acquire"

        /// RTC platform engine creation.
        case engineCreate = "engine.create"

        /// Shared Agora engine initialization.
        case sharedEngine = "agora.sharedEngine"

        /// Enabling the engine's video capabilities.
        case enableVideo = "agora.enableVideo"

        /// Disabling default native camera capture.
        case disableLocalVideo = "agora.disableLocalVideo"

        /// Disabling default microphone capture.
        case disableLocalAudio = "agora.disableLocalAudio"

        /// Resolving the camera capture format.
        case resolveFormat = "camera.resolveFormat"

        /// Checking or requesting camera permission.
        case cameraPermission = "camera.permission"

        /// Checking or requesting microphone permission.
        case microphonePermission = "camera.microphonePermission"

        /// Resolving a camera device identifier.
        case resolveDevice = "camera.resolveDevice"

        /// Configuring the RTC video input source.
        case externalVideoSource = "camera.externalVideoSource"

        /// Creating the local preview presenter.
        case createPreview = "camera.createPreview"

        /// Starting the selected capture manager.
        case captureStart = "camera.captureStart"

        /// The wait for the capture control queue.
        case captureQueueWait = "capture.queueWait"

        /// Opening the capture session configuration.
        case captureBeginConfiguration = "capture.beginConfiguration"

        /// Configuring the capture input.
        case captureInputSetup = "capture.inputSetup"

        /// Discovering available camera devices.
        case captureDeviceDiscovery = "capture.deviceDiscovery"

        /// Selecting a supported capture format.
        case captureFormatSelection = "capture.formatSelection"

        /// Creating the camera device input.
        case captureInputCreate = "capture.inputCreate"

        /// Applying capture device settings.
        case captureDeviceConfiguration = "capture.deviceConfiguration"

        /// Configuring decoded frame output.
        case captureOutputSetup = "capture.outputSetup"

        /// Committing capture session settings.
        case captureCommitConfiguration = "capture.commitConfiguration"

        /// Starting the capture session.
        case captureStartRunning = "capture.startRunning"

        /// The wait for the first delivered raw camera frame.
        case firstCapturedFrame = "capture.firstDeliveredFrame"

        /// Configuring interpolation for the prepared media.
        case interpolationConfiguration = "media.interpolationConfiguration"

        /// Registering preview readiness observation.
        case previewReadinessRegistration = "media.previewReadinessRegistration"

        /// RTC room joining through its success callback.
        case rtcRoomJoin = "rtc.roomJoinAndCallback"

        /// The platform room join invocation.
        case rtcJoinCall = "rtc.roomJoinCall"

        /// The native Agora channel join invocation.
        case agoraJoinCall = "agora.joinChannelEx"

        /// Registering the remote video frame observer.
        case registerVideoObserver = "agora.registerVideoObserver"

        /// Enabling native Agora camera input.
        case enableNativeCamera = "agora.enableLocalVideo"

        /// Starting native Agora camera capture.
        case startNativeCamera = "agora.startCameraCapture"

        /// Starting native preview capture.
        case startNativePreview = "agora.startPreview"

        /// Attaching the native renderer to its AppKit canvas.
        case attachNativePreview = "agora.setupLocalVideo"

        /// The wait for the first native preview frame.
        case firstNativePreviewFrame = "camera.firstPreviewFrame"
    }

    /// The completion, failure, or cancellation outcome of a diagnostic span.
    enum Outcome: String, Sendable {

        /// A span that completed, failed, or ended through cancellation, respectively.
        case completed, failed, cancelled
    }

    /// One diagnostic event with offsets measured from its trace origin.
    struct Record: Sendable {

        /// The preparation trace that produced this event.
        let traceID: UUID

        /// The operation being measured.
        let stage: Stage

        /// The terminal outcome, or `nil` for a span-start event.
        let outcome: Outcome?

        /// The event offset from the trace origin, in milliseconds.
        let offsetMs: Double

        /// The elapsed span duration, in milliseconds, for terminal events.
        let durationMs: Double?

        /// The diagnostic log entry with trace identity, operation, and timing.
        var message: String {
            let duration =
                durationMs.map {
                    String(
                        format: " duration=%.3f ms",
                        $0
                    )
                } ?? ""
            return
                "Local media preparation [\(traceID)] stage=\(stage.rawValue) event=\(outcome?.rawValue ?? "started")"
                + String(
                    format: " offset=%.3f ms",
                    offsetMs
                ) + duration
        }
    }

    /// The identity, monotonic clock, and event destination for one preparation flow.
    final class Trace: Sendable {

        /// The identity shared by events in this preparation flow.
        let id: UUID

        /// The trace start time in monotonic nanoseconds.
        private let origin: UInt64

        /// The monotonic clock returning nanoseconds.
        fileprivate let now: @Sendable () -> UInt64

        /// The destination receiving diagnostic records.
        private let emit: @Sendable (Record) -> Void

        /// Creates a preparation trace with a clock and event destination.
        init(
            id: UUID = UUID(),
            now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            emit: @escaping @Sendable (Record) -> Void = {
                XmaxLogger.media.info(
                    message: $0.message,
                    option: .performance
                )
            }
        ) {
            self.id = id
            self.now = now
            self.emit = emit
            origin = now()
        }

        /// Records a span start and returns its completion handle.
        func begin(
            _ stage: Stage
        ) -> Span {
            let startedAt = now()
            record(
                stage,
                outcome: nil,
                at: startedAt,
                duration: nil
            )
            return Span(
                trace: self,
                stage: stage,
                startedAt: startedAt
            )
        }

        /// Emits an event with offsets and durations converted to milliseconds.
        fileprivate func record(
            _ stage: Stage,
            outcome: Outcome?,
            at time: UInt64,
            duration: UInt64?
        ) {
            emit(
                Record(
                    traceID: id,
                    stage: stage,
                    outcome: outcome,
                    offsetMs: Double(time >= origin ? time - origin : 0) / 1_000_000,
                    durationMs: duration.map { Double($0) / 1_000_000 }
                )
            )
        }
    }

    /// Retains its trace across dispatch queues and can finish only once, including during cancellation.
    final class Span: @unchecked Sendable {

        /// The trace retained until span completion.
        private let trace: Trace

        /// The operation measured by this span.
        private let stage: Stage

        /// The span start time in monotonic nanoseconds.
        private let startedAt: UInt64

        /// The lock protecting completion from concurrent callers.
        private let lock = NSLock()

        /// Whether a terminal event has already been emitted.
        private var finished = false

        /// Creates a span for a measured operation and start time.
        fileprivate init(
            trace: Trace,
            stage: Stage,
            startedAt: UInt64
        ) {
            self.trace = trace
            self.stage = stage
            self.startedAt = startedAt
        }

        /// Emits the first terminal event and returns whether this call completed the span.
        @discardableResult
        func finish(
            _ outcome: Outcome = .completed
        ) -> Bool {
            let shouldFinish = lock.withLock {
                guard !finished else { return false }
                finished = true
                return true
            }
            guard shouldFinish else { return false }
            let endedAt = trace.now()
            trace.record(
                stage,
                outcome: outcome,
                at: endedAt,
                duration: endedAt >= startedAt ? endedAt - startedAt : 0
            )
            return true
        }
    }

    /// Measures a synchronous operation and records its result without changing error propagation.
    static func measure<T>(
        _ stage: Stage,
        _ operation: () throws -> T
    ) rethrows -> T {
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

    /// Measures an asynchronous operation on the caller's isolation and records its result.
    static func measureAsync<T>(
        _ stage: Stage,
        isolation: isolated (any Actor)? = #isolation,
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

    /// Classifies a thrown error as cancellation or failure.
    private static func outcome(
        for error: any Error
    ) -> Outcome {
        error is CancellationError || (error as? XmaxError)?.code == .cancelled ? .cancelled : .failed
    }
}

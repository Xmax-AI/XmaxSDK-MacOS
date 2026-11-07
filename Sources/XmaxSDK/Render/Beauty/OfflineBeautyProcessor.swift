//
//  OfflineBeautyProcessor.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreVideo
import Foundation
@preconcurrency import IOSurface
#if SWIFT_PACKAGE
internal import BeautyIPC
#endif

/// Serializes bounded XPC requests to a private helper, isolating Agora's process-wide engine state.
final class OfflineBeautyProcessor: BeautyProcessing, @unchecked Sendable {

    /// A cross-process response whose surface is protected by a native buffer lease.
    private enum Response: @unchecked Sendable {
        /// A configuration result; nil denotes success.
        case configured(String?)
        /// An output surface, its native pool lease, and an optional processing error.
        case frame(IOSurface?, UInt64, Int, String?)
        /// A transport failure resolved independently of the realtime session.
        case failure(String)
    }

    /// Accepts the first reply or XPC failure and wakes a bounded worker wait.
    private final class Reply: @unchecked Sendable {
        /// Wakes the worker after one response.
        let semaphore = DispatchSemaphore(value: 0)
        /// Protects the response across XPC callback and worker queues.
        private let lock = NSLock()
        /// The first response; later completion attempts are ignored.
        private var stored: Response?

        /// Records a response exactly once.
        func complete(
            _ response: Response
        ) {
            lock.withLock {
                guard stored == nil else { return }
                stored = response
                semaphore.signal()
            }
        }

        /// Waits off the main actor, throwing on a transport failure or timeout.
        func wait(
            seconds: Double
        ) throws -> Response {
            guard semaphore.wait(timeout: .now() + seconds) == .success,
                let response = lock.withLock({ stored }) else {
                throw XmaxError(code: .mediaError, message: "The result beauty helper timed out")
            }
            if case let .failure(message) = response {
                throw XmaxError(code: .mediaError, message: message)
            }
            return response
        }
    }

    /// Owns process resources exclusively on the worker queue, including deferred destruction.
    private final class Storage: @unchecked Sendable {
        /// The app-private XPC peer.
        var connection: NSXPCConnection?
        /// Converts supported SDR colors before transferring their surfaces to ClearVision.
        let colorConverter = BeautyColorConverter()
        /// Prevents a closed processor from activating another connection.
        var closed = false

        /// Invalidates the private connection; its service releases this client's native graph resources.
        func shutdown() {
            connection?.invalidate()
            connection = nil
            colorConverter.close()
            closed = true
        }
    }

    /// Releases a native pool lease only after every host consumer releases its CVPixelBuffer.
    private final class SurfaceLease: NSObject {
        /// Returns the native pool lease on the client worker.
        let release: @Sendable () -> Void
        /// Attaches lease release to the lifetime of the host pixel buffer.
        init(
            release: @escaping @Sendable () -> Void
        ) { self.release = release }
        /// Runs only after all host consumers release the pixel buffer.
        deinit { release() }
    }

    /// Confines process state and keeps the frame pipeline's single in-flight request off the main actor.
    private let worker = DispatchQueue(label: "ai.xmax.result-beauty", qos: .userInitiated)

    /// The child process and anonymous connection owned by this processor.
    private let storage = Storage()

    /// Creates a helper-backed processor without creating capture devices or RTC connections.
    static func make(
        _ options: RealtimeVideoBeautyOptions
    ) async throws -> any BeautyProcessing {
        let processor = OfflineBeautyProcessor()
        try await processor.update(options)
        return processor
    }

    /// Stops private processing even when an integration omits explicit cleanup.
    deinit {
        let storage = storage
        worker.async { storage.shutdown() }
    }

    /// Applies validated options, starting the signed embedded helper lazily.
    func update(
        _ options: RealtimeVideoBeautyOptions
    ) async throws {
        try options.validate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            worker.async { [self] in
                do {
                    if storage.connection == nil { try start() }
                    let reply = Reply()
                    let proxy = try proxy(reply: reply)
                    proxy.configure(RtcEngineManager.defaultAppID, options: [
                        "enable": true,
                        "smoothness": NSNumber(value: options.smoothness),
                        "lightness": NSNumber(value: options.lightening),
                        "sharpness": NSNumber(value: options.sharpness),
                        "redness": NSNumber(value: options.redness),
                        "contrast": 1
                    ]) { reply.complete(.configured($0)) }
                    guard case let .configured(error) = try reply.wait(seconds: 3) else {
                        throw Self.error("Invalid beauty helper configuration reply")
                    }
                    if let error { throw Self.error(error) }
                    continuation.resume()
                } catch {
                    storage.shutdown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Processes one shared surface, preserving PTS and duration for preview and frame output.
    func process(
        _ input: BeautyFrameInput
    ) async throws -> RealtimeVideoFrame {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            worker.async { [self] in
                do {
                    let frame = try input.resolve(using: storage.colorConverter)
                    guard let surface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue() else {
                        throw Self.error("Result beauty requires an IOSurface-backed pixel buffer")
                    }
                    let reply = Reply()
                    try proxy(reply: reply).process(surface) { reply.complete(.frame($0, $1, $2, $3)) }
                    guard case let .frame(result, lease, code, error) = try reply.wait(seconds: 0.5) else {
                        throw Self.error("Invalid beauty helper frame reply")
                    }
                    if code == Int(kCVReturnWouldExceedAllocationThreshold) {
                        throw BeautyProcessingError.outputBackpressure
                    }
                    if let error { throw Self.error(error) }
                    guard let result, lease != 0 else { throw Self.error("The beauty helper returned no frame") }
                    var outputReference: Unmanaged<CVPixelBuffer>?
                    guard CVPixelBufferCreateWithIOSurface(nil, result, nil, &outputReference) == kCVReturnSuccess,
                        let output = outputReference?.takeRetainedValue(),
                        CVPixelBufferGetWidth(output) == CVPixelBufferGetWidth(frame.pixelBuffer),
                        CVPixelBufferGetHeight(output) == CVPixelBufferGetHeight(frame.pixelBuffer) else {
                        releaseFrame(lease)
                        throw Self.error("Unable to open the processed beauty surface")
                    }
                    let owner = SurfaceLease { [weak self] in self?.releaseFrame(lease) }
                    CVBufferSetAttachment(output, "ai.xmax.beauty.lease" as CFString, owner, .shouldNotPropagate)
                    CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey,
                                          kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey,
                                          kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
                                          kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                    continuation.resume(returning: RealtimeVideoFrame(
                        pixelBuffer: output,
                        presentationTimeStamp: frame.presentationTimeStamp,
                        duration: frame.duration
                    ))
                } catch BeautyProcessingError.outputBackpressure {
                    continuation.resume(throwing: BeautyProcessingError.outputBackpressure)
                } catch {
                    storage.shutdown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Invalidates the private connection after pending work without touching the realtime engine.
    func close() async {
        await withCheckedContinuation { continuation in
            worker.async { [storage] in
                storage.shutdown()
                continuation.resume()
            }
        }
    }

    /// Returns the authenticated peer PID for signed-host integration diagnostics.
    func diagnosticProcessIdentifier() async -> Int32 {
        await withCheckedContinuation { continuation in
            worker.async { [storage] in
                continuation.resume(returning: storage.connection?.processIdentifier ?? 0)
            }
        }
    }

    /// Sends the release when asynchronous preview and transport ownership ends.
    private func releaseFrame(
        _ lease: UInt64
    ) {
        worker.async { [storage] in
            guard let connection = storage.connection else { return }
            (connection.remoteObjectProxyWithErrorHandler { _ in } as? BeautyWorkerProtocol)?.releaseFrame(lease)
        }
    }

    /// Forwards a connection failure into the active request's bounded wait.
    private func proxy(
        reply: Reply
    ) throws -> any BeautyWorkerProtocol {
        guard !storage.closed, let connection = storage.connection,
            let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                reply.complete(.failure("Result beauty helper disconnected: \(error.localizedDescription)"))
            }) as? BeautyWorkerProtocol else {
            throw Self.error("The result beauty helper is unavailable")
        }
        return proxy
    }

    /// Activates the owning app's private XPC service with the system launch and sandbox lifecycle.
    private func start() throws {
        guard !storage.closed else { throw Self.error("The result beauty processor is closed") }
        let service = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/XmaxRealtimeBeautyWorker.xpc")
        guard FileManager.default.fileExists(atPath: service.path) else {
            throw Self.error("Embed XmaxRealtimeBeautyWorker.xpc in Contents/XPCServices to enable result beauty")
        }
        guard let serviceName = Bundle(url: service)?.bundleIdentifier, !serviceName.isEmpty else {
            throw Self.error("The result beauty service requires a bundle identifier")
        }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = BeautyWorkerInterface.make()
        connection.resume()
        storage.connection = connection
    }

    /// Creates a recoverable processing error distinct from fatal generation state.
    private static func error(
        _ message: String
    ) -> XmaxError {
        XmaxError(code: .mediaError, message: message)
    }
}

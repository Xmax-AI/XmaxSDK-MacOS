// Copyright (c) 2026 XMAX.AI PTE. LTD.

import CoreVideo
import Foundation
@preconcurrency import IOSurface
import BeautyBridge
import BeautyIPC

/// Entry point for the signed, independently sandboxed beauty helper bundled by the host app.
public enum XmaxRealtimeBeautyWorker {

    /// Runs the private XPC service embedded in the host's Contents/XPCServices directory.
    /// Call only from the service executable's main entry point; this never creates an RTC connection.
    public static func run() -> Never {
        let server = BeautyWorkerServer()
        let listener = NSXPCListener.service()
        listener.delegate = server
        listener.resume()
        withExtendedLifetime((server, listener)) { dispatchMain() }
    }
}

/// Retains a shared surface while a Sendable queue operation is pending.
private struct BorrowedSurface: @unchecked Sendable {
    let value: IOSurface
}

/// Exposes private, connection-scoped settings while sharing one offline vendor service per process.
private final class BeautyWorkerServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let engine = BeautyWorkerEngine()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = BeautyWorkerService(engine: engine)
        connection.exportedInterface = BeautyWorkerInterface.make()
        connection.exportedObject = service
        connection.invalidationHandler = { service.close() }
        connection.resume()
        return true
    }
}

/// One connection's configuration and output leases, confined to the engine worker queue.
final class BeautyWorkerContext: @unchecked Sendable {
    var options: [String: NSNumber]?
    var appID: String?
    var leases: [UInt64: CVPixelBuffer] = [:]
    var nextLease: UInt64 = 0
    var closed = false

    /// Identifies the pool this connection last used without keeping a retired graph alive.
    weak var processor: BeautyProcessor?
}

/// Serializes all vendor calls; separate clients never initialize a second Agora service in this process.
final class BeautyWorkerEngine: @unchecked Sendable {
    let worker = DispatchQueue(label: "ai.xmax.beauty-worker", qos: .userInitiated)
    private var processor: BeautyProcessor?
    private var currentOptions: [String: NSNumber]?

    func prepare(appID: String, options: [String: NSNumber], for context: BeautyWorkerContext) throws -> BeautyProcessor {
        if let processor {
            if currentOptions != options { try processor.updateOptions(options) }
        } else {
            processor = try BeautyProcessor(appID: appID, options: options)
        }
        guard let processor else { throw WorkerError("Unable to create beauty processor") }
        currentOptions = options
        context.processor = processor
        return processor
    }

    func frameFailureCode(_ error: any Error, for context: BeautyWorkerContext) -> Int {
        let failure = error as NSError
        guard failure.domain == "ai.xmax.video-beauty" else { return -1 }
        if failure.code == BeautyWorkerFrameStatus.unavailable.rawValue {
            // Retire the failed graph on the worker queue before replying to the reconnecting client.
            retireProcessor(for: context)
            context.closed = true
        }
        return failure.code
    }

    func close(_ context: BeautyWorkerContext) {
        context.closed = true
        // Destroy the connection's pool before releasing leases for surfaces the host may still retain.
        retireProcessor(for: context)
        context.leases.removeAll()
        context.options = nil
    }

    private func retireProcessor(for context: BeautyWorkerContext) {
        guard let processor, processor === context.processor else { return }
        processor.close()
        self.processor = nil
        currentOptions = nil
        context.processor = nil
    }
}

/// Serves one connection without sharing its settings or ownership leases with other connections.
private final class BeautyWorkerService: NSObject, BeautyWorkerProtocol, @unchecked Sendable {
    private let engine: BeautyWorkerEngine
    private let context = BeautyWorkerContext()

    init(engine: BeautyWorkerEngine) { self.engine = engine }

    func configure(_ appID: String, options: [String: NSNumber], reply: @escaping @Sendable (String?) -> Void) {
        engine.worker.async { [self] in
            do {
                guard !context.closed else { throw WorkerError("Beauty connection is closed") }
                _ = try engine.prepare(appID: appID, options: options, for: context)
                context.appID = appID
                context.options = options
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    func process(_ surface: IOSurface, reply: @escaping @Sendable (IOSurface?, UInt64, Int, String?) -> Void) {
        let surface = BorrowedSurface(value: surface)
        engine.worker.async { [self] in
            do {
                guard !context.closed, let options = context.options, let appID = context.appID else {
                    throw WorkerError("Beauty worker is not configured")
                }
                let processor = try engine.prepare(appID: appID, options: options, for: context)
                var inputReference: Unmanaged<CVPixelBuffer>?
                guard CVPixelBufferCreateWithIOSurface(nil, surface.value, nil, &inputReference) == kCVReturnSuccess,
                    let input = inputReference?.takeRetainedValue() else {
                    throw WorkerError("Unable to open the input surface")
                }
                let output = try processor.processPixelBuffer(input)
                guard let result = CVPixelBufferGetIOSurface(output)?.takeUnretainedValue() else {
                    throw WorkerError("Beauty output has no shared surface")
                }
                context.nextLease &+= 1
                context.leases[context.nextLease] = output
                reply(result, context.nextLease, 0, nil)
            } catch {
                let code = engine.frameFailureCode(error, for: context)
                reply(nil, 0, code, error.localizedDescription)
            }
        }
    }

    func releaseFrame(_ lease: UInt64) {
        engine.worker.async { [context] in context.leases.removeValue(forKey: lease) }
    }

    func close() {
        engine.worker.async { [self] in engine.close(context) }
    }
}

/// A local helper failure converted to a recoverable host-side media error.
private struct WorkerError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

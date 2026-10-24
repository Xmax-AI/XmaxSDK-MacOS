//
//  RtcMessageQueue.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Splits room JSON signals into Agora DataStream fragments matching the server protocol.
enum RtcMessageCodec {

    /// Encodes UTF-8 signals as single packets or reassemblable JSON fragments.
    ///
    /// - Parameter message: The complete room signal.
    ///
    /// - Returns: The packets in send order.
    ///
    /// - Throws: An error on empty signals, size or fragment count limits, or JSON encoding failure.
    static func encode(
        _ message: String
    ) throws -> [Data] {
        let bytes = Data(message.utf8)
        guard !bytes.isEmpty, bytes.count <= 256 * 1024 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "RTC room message must contain between 1 and 262144 bytes"
            )
        }
        if bytes.count <= 800 { return [bytes] }

        var chunks: [String] = []
        var chunk = ""
        var length = 0
        for scalar in message.unicodeScalars {
            let value = String(scalar)
            let encoded = try JSONEncoder().encode(value).count - 2
            if length + encoded > 600 {
                chunks.append(chunk)
                chunk = ""
                length = 0
            }
            chunk += value
            length += encoded
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        guard chunks.count <= 512 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "RTC room message contains too many fragments"
            )
        }

        let eventID = UUID().uuidString.replacingOccurrences(
            of: "-",
            with: ""
        )
        return try chunks.enumerated().map { index, chunk in
            try JSONEncoder().encode(
                Fragment(
                    eventId: eventID,
                    index: index,
                    count: chunks.count,
                    data: chunk
                )
            )
        }
    }

    /// A large signal fragment with reassembly information.
    private struct Fragment: Encodable {

        /// The signaling fragmentation event name.
        let event = "__agora_chunk__"

        /// The identifier associating fragments of one message.
        let eventId: String

        /// The fragment index within the message.
        let index: Int

        /// The total fragment count.
        let count: Int

        /// The encoded fragment contents.
        let data: String
    }
}

/// Sends complete signal groups serially and limits DataStream packets and bytes per second.
final class RtcMessageQueue: @unchecked Sendable {

    /// The operation submitting one packet.
    private let send: @Sendable (Data) throws -> Void

    /// The handler for reportable asynchronous send failures.
    private let onFailure: @Sendable (XmaxError) -> Void

    /// The packet and byte rate limiter.
    private let limiter = RateLimiter()

    /// The lock protecting tasks, coalescing, and closure state.
    private let lock = NSLock()

    /// Whether the queue is closed.
    private var closed = false

    /// The incomplete send tasks keyed by message identifier.
    private var tasks: [UUID: Task<Void, any Error>] = [:]

    /// The preceding task preserving message order.
    private var lastTask: Task<Void, any Error>?

    /// Whether failure of the last queued message blocks later messages.
    private var lastFailureIsFatal = true

    /// Creates a serial, rate-limited room signaling queue.
    init(
        send: @escaping @Sendable (Data) throws -> Void,
        onFailure: @escaping @Sendable (XmaxError) -> Void
    ) {
        self.send = send
        self.onFailure = onFailure
    }

    /// Enqueues a complete signal for serial sending.
    ///
    /// - Parameters:
    ///   - message: The complete signal to send.
    ///   - reportFailure: Whether asynchronous send failure invokes the fault callback.
    ///
    /// - Returns: A task for independently awaiting this signal's send result.
    ///
    /// - Throws: An error on encoding failure, closed queue, or full queue.
    @discardableResult
    func enqueue(
        _ message: String,
        reportFailure: Bool = true
    ) throws -> Task<Void, any Error> {
        let packets = try RtcMessageCodec.encode(message)
        return try lock.withLock {
            guard !closed else { throw CancellationError() }
            guard tasks.count < 64 else {
                throw XmaxError(
                    code: .rtcError,
                    message: "RTC room message queue is full"
                )
            }

            let previous = lastTask
            let previousFailureIsFatal = lastFailureIsFatal
            let id = UUID()
            let task = Task { [self] in
                defer { _ = lock.withLock { tasks.removeValue(forKey: id) } }
                do {
                    if previousFailureIsFatal {
                        try await previous?.value
                    } else {
                        _ = try? await previous?.value
                    }
                    for packet in packets {
                        try await limiter.wait(byteCount: packet.count)
                        try Task.checkCancellation()
                        try send(packet)
                    }
                } catch {
                    if !Task.isCancelled, !lock.withLock({ closed }) {
                        if reportFailure {
                            onFailure(XmaxError.from(error))
                        } else {
                            XmaxLogger.rtc.warn(
                                message:
                                    "发送配置失败 (Failed to Send Configuration)\n└─ \(ErrorMessageFormatter.format(error))"
                            )
                        }
                    }
                    throw error
                }
            }
            tasks[id] = task
            lastTask = task
            lastFailureIsFatal = reportFailure
            return task
        }
    }

    /// Waits for signals already queued at call time to finish sending.
    ///
    /// - Throws: An error on send failure or cancelled waiting.
    func flush() async throws {
        let pending = lock.withLock { lastTask }
        try await Self.waitForCompletion(of: pending)
    }

    /// Waits for a specific signal, unaffected by later messages.
    ///
    /// - Parameter pending: The send task to await; `nil` requires no wait.
    ///
    /// - Throws: An error if the task fails or waiting is cancelled.
    static func waitForCompletion(
        of pending: Task<Void, any Error>?
    ) async throws {
        let completion = AsyncThrowingStream<Void, any Error> { continuation in
            let observer = Task {
                do {
                    try await pending?.value
                    continuation.yield()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in observer.cancel() }
        }
        for try await _ in completion {}
        try Task.checkCancellation()
    }

    /// Closes the send queue and cancels unfinished signals.
    func close() {
        lock.withLock {
            closed = true
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
            lastTask = nil
        }
    }
}

private extension RtcMessageQueue {

    /// Limits packet count and total bytes using a sliding time window.
    actor RateLimiter {

        /// The send timestamps and byte counts in the current window.
        var sent: [(time: UInt64, bytes: Int)] = []

        /// Waits for sufficient packet and byte budget in the send window.
        ///
        /// - Parameter byteCount: The byte count of the packet to send.
        ///
        /// - Throws: Cancellation if waiting is cancelled.
        func wait(
            byteCount: Int
        ) async throws {
            while true {
                try Task.checkCancellation()
                let now = DispatchTime.now().uptimeNanoseconds
                sent.removeAll { now - $0.time >= 1000000000 }
                if sent.count < 28,
                    sent.reduce(
                        0,
                        { $0 + $1.bytes }
                    ) + byteCount <= 5800
                {
                    sent.append((now, byteCount))
                    return
                }
                let elapsed = now - sent[0].time
                try await Task.sleep(nanoseconds: 1000000000 - elapsed)
            }
        }
    }
}

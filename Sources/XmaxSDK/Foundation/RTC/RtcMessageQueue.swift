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

/// Encodes signaling into Agora data-stream packets for server reassembly.
enum RtcMessageCodec {

    /// Encodes UTF-8 signaling as one packet or reassemblable JSON fragments.
    ///
    /// - Parameter message: The complete room message.
    ///
    /// - Returns: The packets in send order.
    ///
    /// - Throws: An error if the message is empty, exceeds limits, or cannot be encoded.
    static func encode(
        _ message: String
    ) throws -> [Data] {
        let byteCount = message.utf8.count
        guard byteCount > 0, byteCount <= 256 * 1024 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "RTC room message must contain between 1 and 262144 bytes"
            )
        }
        if byteCount <= 800 {
            return [Data(message.utf8)]
        }

        var chunks: [String] = []
        var chunk = ""
        var length = 0
        for scalar in message.unicodeScalars {
            let encoded = escapedByteCount(scalar)
            if length + encoded > 600 {
                chunks.append(chunk)
                chunk = ""
                length = 0
            }
            chunk.unicodeScalars.append(scalar)
            length += encoded
        }

        if !chunk.isEmpty {
            chunks.append(chunk)
        }

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
        let encoder = JSONEncoder()
        return try chunks.enumerated().map { index, chunk in
            try encoder.encode(
                Fragment(
                    eventId: eventID,
                    index: index,
                    count: chunks.count,
                    data: chunk
                )
            )
        }
    }

    /// Counts the UTF-8 bytes a scalar occupies in a default JSONEncoder string.
    private static func escapedByteCount(
        _ scalar: Unicode.Scalar
    ) -> Int {
        switch scalar.value {
        case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x2F, 0x5C: 2
        case 0x00...0x1F: 6
        case 0x20...0x7F: 1
        case 0x80...0x7FF: 2
        case 0x800...0xFFFF: 3
        default: 4
        }
    }

    /// A signaling fragment with reassembly metadata.
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

/// An ordered signaling queue respecting data-stream packet and byte limits.
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

    /// The latest unsent message for each coalescing key.
    private var pendingMessages: [String: PendingMessage] = [:]

    /// Creates an ordered, rate-limited signaling queue.
    init(
        send: @escaping @Sendable (Data) throws -> Void,
        onFailure: @escaping @Sendable (XmaxError) -> Void
    ) {
        self.send = send
        self.onFailure = onFailure
    }

    /// Enqueues a complete signaling message.
    ///
    /// - Parameters:
    ///   - message: The complete message to send.
    ///   - reportFailure: Whether asynchronous send failure triggers the failure handler.
    ///   - key: The key replacing older messages that have not started sending.
    ///
    /// - Returns: The send task. Coalesced calls share a task sending the latest retained message.
    ///
    /// - Throws: An error if encoding fails or the queue is closed or full.
    @discardableResult
    func enqueue(
        _ message: String,
        reportFailure: Bool = true,
        replacingPendingMessage key: String? = nil
    ) throws -> Task<Void, any Error> {
        let packets = try RtcMessageCodec.encode(message)
        return try lock.withLock {
            guard !closed else {
                throw CancellationError()
            }

            if let key, let pending = pendingMessages[key], let task = tasks[pending.id] {
                pendingMessages[key] = PendingMessage(
                    id: pending.id,
                    packets: packets
                )
                return task
            }

            guard tasks.count < 64 else {
                throw XmaxError(
                    code: .rtcError,
                    message: "RTC room message queue is full"
                )
            }

            let previous = lastTask
            let previousFailureIsFatal = lastFailureIsFatal
            let id = UUID()
            if let key {
                pendingMessages[key] = PendingMessage(
                    id: id,
                    packets: packets
                )
            }

            let task = Task { [self] in
                defer {
                    lock.withLock {
                        tasks.removeValue(forKey: id)
                        if let key, pendingMessages[key]?.id == id {
                            pendingMessages.removeValue(forKey: key)
                        }
                    }
                }

                do {
                    if previousFailureIsFatal {
                        try await previous?.value
                    } else {
                        _ = try? await previous?.value
                    }

                    try Task.checkCancellation()
                    let currentPackets: [Data]
                    if let key {
                        currentPackets = try await takePendingPackets(
                            key: key,
                            id: id
                        )
                    } else {
                        currentPackets = packets
                    }

                    for packet in currentPackets {
                        try await limiter.wait(byteCount: packet.count)
                        try Task.checkCancellation()
                        try send(packet)
                        await limiter.record(byteCount: packet.count)
                    }
                } catch {
                    // Discarding an unsent message must not block subsequent control messages.
                    if Task.isCancelled, key != nil,
                        !lock.withLock({
                            closed
                        })
                    {
                        return
                    }

                    if !Task.isCancelled,
                        !lock.withLock({
                            closed
                        })
                    {
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

    /// Drops unsent coalescible messages without affecting active fragments or control messages.
    ///
    /// - Parameter key: The coalescing key, or `nil` for all coalescible messages.
    func discardPendingMessages(
        key: String? = nil
    ) {
        lock.withLock {
            let keys =
                key.map {
                    [$0]
                } ?? Array(pendingMessages.keys)
            for key in keys {
                if let pending = pendingMessages.removeValue(forKey: key) {
                    tasks[pending.id]?.cancel()
                }
            }
        }
    }

    /// Waits for a specific message independently of subsequently queued messages.
    ///
    /// - Parameter pending: The send task to await.
    ///
    /// - Throws: An error if the task fails or waiting is cancelled.
    static func waitForCompletion(
        of pending: Task<Void, any Error>
    ) async throws {
        let completion = AsyncThrowingStream<Void, any Error> { continuation in
            let observer = Task {
                do {
                    try await pending.value
                    continuation.yield()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                observer.cancel()
            }
        }

        for try await _ in completion {
        }

        try Task.checkCancellation()
    }

    /// Closes the queue and cancels incomplete messages.
    func close() {
        lock.withLock {
            closed = true
            tasks.values.forEach {
                $0.cancel()
            }
            tasks.removeAll()
            lastTask = nil
            pendingMessages.removeAll()
        }
    }
}

private extension RtcMessageQueue {

    /// The latest contents of an unsent message.
    struct PendingMessage {

        /// The pending message task identifier.
        let id: UUID

        /// The message fragments within packet size limits.
        let packets: [Data]
    }

    /// Claims the latest message contents when send quota becomes available.
    ///
    /// - Parameters:
    ///   - key: The message coalescing key.
    ///   - id: The send task identifier.
    ///
    /// - Returns: The complete fragments to begin sending.
    ///
    /// - Throws: A cancellation error if the queue is closed or the message was discarded.
    func takePendingPackets(
        key: String,
        id: UUID
    ) async throws -> [Data] {
        while true {
            try Task.checkCancellation()
            let byteCount = try lock.withLock {
                guard let pending = pendingMessages[key], pending.id == id else {
                    throw CancellationError()
                }
                return pending.packets[0].count
            }

            try await limiter.wait(byteCount: byteCount)
            let packets: [Data]? = try lock.withLock {
                guard !closed, let pending = pendingMessages[key], pending.id == id else {
                    throw CancellationError()
                }
                guard pending.packets[0].count <= byteCount else {
                    return nil
                }
                pendingMessages.removeValue(forKey: key)
                return pending.packets
            }
            if let packets {
                return packets
            }
        }
    }

    /// A sliding-window limiter for signaling packets and bytes. Allows headroom below the
    /// per-channel 60 packets/s and client-wide 30 KB/s limits.
    actor RateLimiter {

        /// The send timestamps and byte counts in the current window.
        var sent: [(time: UInt64, bytes: Int)] = []

        /// Waits for sufficient packet and byte quota.
        ///
        /// - Parameter byteCount: The packet size, in bytes.
        ///
        /// - Throws: A cancellation error if waiting is cancelled.
        func wait(
            byteCount: Int
        ) async throws {
            while true {
                try Task.checkCancellation()
                let now = DispatchTime.now().uptimeNanoseconds
                sent.removeAll {
                    now - $0.time >= 1000000000
                }
                if sent.count < 58,
                    sent.reduce(
                        0,
                        {
                            $0 + $1.bytes
                        }
                    ) + byteCount <= 29000
                {
                    return
                }

                let elapsed = now - sent[0].time
                try await Task.sleep(nanoseconds: 1000000000 - elapsed)
            }
        }

        /// Accounts for a submitted packet in the current send window.
        ///
        /// - Parameter byteCount: The submitted packet size, in bytes.
        func record(
            byteCount: Int
        ) {
            sent.append((DispatchTime.now().uptimeNanoseconds, byteCount))
        }
    }
}

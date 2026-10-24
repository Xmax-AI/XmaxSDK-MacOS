//
//  RtcEngineManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// An exclusive lease on the process-wide RTC engine.
final class RtcEngineLease: @unchecked Sendable {

    /// The leased platform engine.
    let engine: any RtcPlatform

    /// The unique lease identifier.
    let id = UUID()

    /// Creates an exclusive lease retaining the specified engine.
    fileprivate init(
        engine: any RtcPlatform
    ) {
        self.engine = engine
    }
}

/// Manages exclusive process-wide RTC engine creation, queued leasing, and destruction.
actor RtcEngineManager {

    /// Creates a platform engine from an RTC application identifier; nil on failure.
    typealias EngineFactory = @Sendable (String) -> (any RtcPlatform)?

    /// Destroys the current process-wide RTC platform engine.
    typealias EngineDestructor = @Sendable () -> Void

    /// The shared engine lease manager.
    static let shared = RtcEngineManager()

    /// The default RTC application identifier.
    static let defaultAppID = "5588dfe2e7874bd08ea28f4968ec2d40"

    /// The RTC application identifier.
    private let appID: String

    /// The factory invoked after exclusive access is obtained.
    private let makeEngine: EngineFactory

    /// The destructor invoked when a lease is released.
    private let destroyEngine: EngineDestructor

    /// The active exclusive lease.
    private var activeLease: RtcEngineLease?

    /// The pending lease requests in acquisition order.
    private var requests: [Request] = []

    /// Configures engine creation, destruction, and queued lease management.
    init(
        appID: String = RtcEngineManager.defaultAppID,
        makeEngine: @escaping EngineFactory = AgoraRtcPlatform.create,
        destroyEngine: @escaping EngineDestructor = AgoraRtcPlatform.destroyEngine
    ) {
        self.appID = appID
        self.makeEngine = makeEngine
        self.destroyEngine = destroyEngine
    }

    /// Waits for and acquires an exclusive RTC engine lease.
    ///
    /// - Returns: The exclusive lease held by this caller.
    ///
    /// - Throws: An error on cancelled waiting, invalid application identifier, or engine creation failure.
    func acquire() async throws -> RtcEngineLease {
        try Task.checkCancellation()

        if activeLease == nil, requests.isEmpty {
            let lease = try createLease()
            if Task.isCancelled {
                releaseActiveLease(lease)
                throw CancellationError()
            }

            activeLease = lease
            return lease
        }

        let requestID = UUID()
        let lease: RtcEngineLease = try await withTaskCancellationHandler(
            operation: {
                try await self.enqueueRequest(id: requestID)
            },
            onCancel: {
                Task {
                    await self.cancelRequest(id: requestID)
                }
            }
        )

        if Task.isCancelled {
            releaseActiveLease(lease)
            throw CancellationError()
        }

        return lease
    }

    /// Releases a valid lease and transfers engine ownership to the next waiter.
    ///
    /// - Parameter lease: The lease to return; invalid leases do not affect the active engine.
    func release(
        _ lease: RtcEngineLease
    ) {
        guard activeLease?.id == lease.id else {
            return
        }

        releaseActiveLease(lease)
    }

    /// Creates a platform engine wrapped in an exclusive lease.
    ///
    /// - Returns: The newly created engine lease.
    ///
    /// - Throws: An error on an empty application identifier or engine creation failure.
    private func createLease() throws -> RtcEngineLease {
        let normalizedAppID = appID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedAppID.isEmpty else {
            throw XmaxError(
                code: .rtcError,
                message: "RTC App ID cannot be empty"
            )
        }
        guard
            let engine = makeEngine(normalizedAppID)
        else {
            throw XmaxError(
                code: .rtcError,
                message: "Failed to create RTC Engine"
            )
        }

        return RtcEngineLease(engine: engine)
    }

    /// Destroys the engine for a valid lease and resumes queued requests.
    ///
    /// - Parameter lease: The lease to release.
    private func releaseActiveLease(
        _ lease: RtcEngineLease
    ) {
        guard activeLease == nil || activeLease?.id == lease.id else {
            return
        }

        activeLease = nil
        destroyEngine()
        fulfillNextRequest()
    }

    /// Delivers engine leases to waiters in queue order.
    private func fulfillNextRequest() {
        while activeLease == nil, !requests.isEmpty {
            let request = requests.removeFirst()

            do {
                let lease = try createLease()
                activeLease = lease
                request.continuation.resume(returning: lease)
            } catch {
                request.continuation.resume(throwing: error)
            }
        }
    }

    /// Enqueues a lease request.
    ///
    /// - Parameter id: The unique request identifier used for lookup and cancellation.
    ///
    /// - Returns: The exclusive engine lease delivered later.
    ///
    /// - Throws: An error on request cancellation or engine creation failure.
    private func enqueueRequest(
        id: UUID
    ) async throws -> RtcEngineLease {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RtcEngineLease, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }

            requests.append(
                Request(
                    id: id,
                    continuation: continuation
                )
            )
        }
    }

    /// Cancels a queued lease request.
    ///
    /// - Parameter id: The request identifier to cancel.
    private func cancelRequest(
        id: UUID
    ) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else {
            return
        }

        let request = requests.remove(at: index)
        request.continuation.resume(throwing: CancellationError())
    }

}

private extension RtcEngineManager {

    /// Stores a request awaiting exclusive RTC engine access.
    struct Request {

        /// The lease request identifier.
        let id: UUID

        /// The continuation awaiting engine ownership.
        let continuation: CheckedContinuation<RtcEngineLease, any Error>
    }
}

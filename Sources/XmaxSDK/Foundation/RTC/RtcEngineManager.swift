//
//  RtcEngineManager.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// An exclusive lease on the process-wide RTC engine.
final class RtcEngineLease: @unchecked Sendable {

    /// RTC resources
    let engine: any RtcPlatform

    /// Runtime identity
    let id = UUID()

    /// Creates an exclusive lease retaining the specified engine.
    ///
    /// - Parameter engine: The platform engine retained by the lease.
    fileprivate init(engine: any RtcPlatform) {
        self.engine = engine
    }
}

/// Manages exclusive process-wide RTC engine creation, queued leasing, and destruction.
actor RtcEngineManager {
    /// Creates a platform engine from an RTC application identifier; nil on failure.
    typealias EngineFactory = @Sendable (String) -> (any RtcPlatform)?
    /// Destroys the current process-wide RTC platform engine.
    typealias EngineDestructor = @Sendable () -> Void

    /// Shared instance
    static let shared = RtcEngineManager()

    /// RTC configuration
    static let defaultAppID = "5588dfe2e7874bd08ea28f4968ec2d40"

    /// Dependencies
    private let appID: String
    private let makeEngine: EngineFactory
    private let destroyEngine: EngineDestructor

    /// RTC resources
    private var activeLease: RtcEngineLease?

    /// Runtime state
    private var requests: [Request] = []

    /// Configures engine creation, destruction, and queued lease management.
    ///
    /// - Parameters:
    ///   - appID: The RTC application identifier.
    ///   - makeEngine: The engine factory accepting an application identifier.
    ///   - destroyEngine: The operation destroying the current platform engine.
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
    func release(_ lease: RtcEngineLease) {
        guard activeLease?.id == lease.id else {
            return
        }

        releaseActiveLease(lease)
    }

    /// Creates a platform engine wrapped in an exclusive lease.
    ///
    /// - Returns: The newly created engine lease.
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
        guard let engine = LocalMediaPreparationTiming.measure(.engineCreate, { makeEngine(normalizedAppID) }) else {
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
    private func releaseActiveLease(_ lease: RtcEngineLease) {
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
    /// - Returns: The exclusive engine lease delivered later.
    /// - Throws: An error on request cancellation or engine creation failure.
    private func enqueueRequest(id: UUID) async throws -> RtcEngineLease {
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
    private func cancelRequest(id: UUID) {
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

        /// Request identity
        let id: UUID

        /// Lease delivery
        let continuation: CheckedContinuation<RtcEngineLease, any Error>
    }
}

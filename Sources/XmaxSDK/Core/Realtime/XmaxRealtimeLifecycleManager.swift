//
//  XmaxRealtimeLifecycleManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Coordinates realtime operation admission, state commits, and scoped resource cleanup.
actor XmaxRealtimeLifecycleManager {

    /// Distinguishes media preparation, connection, generation, and configuration operations.
    enum OperationKind: Sendable {

        /// Creates, stops, or adjusts local media.
        case media

        /// Establishes a realtime connection.
        case connection

        /// Starts generation.
        case generation

        /// Switches cameras and resumes generation when needed.
        case cameraSwitch

        /// Updates generation conditions or return dimensions without changing the generation lifecycle.
        case configuration
    }

    /// Defines the resources released by a termination operation.
    enum TerminationScope: Int, Sendable {

        /// Stops generation while retaining the established connection and local media.
        case generation = -1

        /// Releases connection and generation resources while retaining local media.
        case connection

        /// Releases connection, generation, and local media resources.
        case all

        /// Checks whether an operation belongs to this cleanup scope.
        ///
        /// - Parameter kind: The operation kind to check.
        ///
        /// - Returns: `true` if the operation belongs to this cleanup scope.
        func affects(
            _ kind: OperationKind
        ) -> Bool {
            switch self {
            case .generation:
                kind == .generation || kind == .configuration || kind == .cameraSwitch
            case .connection:
                kind != .media
            case .all:
                true
            }
        }
    }

    /// Records the session identifier and retained local media after cleanup.
    struct CleanupResult: Sendable {

        /// The session identifier involved in cleanup, if any.
        let sessionID: String?

        /// Whether usable local media remains after cleanup.
        let hasLocalMedia: Bool

        /// Creates a resource cleanup result.
        init(
            sessionID: String? = nil,
            hasLocalMedia: Bool = false
        ) {
            self.sessionID = sessionID
            self.hasLocalMedia = hasLocalMedia
        }
    }

    /// Provides operation validity checks and failure cleanup scope configuration.
    struct Token: Sendable {

        /// The lease that tracks the operation's validity.
        fileprivate let lease: OperationLease

        /// Sets the resource cleanup scope for operation failure or cancellation.
        ///
        /// - Parameter scope: The resource scope to release.
        func setFailureScope(
            _ scope: TerminationScope
        ) {
            lease.setFailureScope(scope)
        }

        /// Checks that the operation remains valid and has not been cancelled.
        ///
        /// - Throws: An error if the operation is invalid or cancelled.
        func ensureCurrent() throws {
            try lease.ensureCurrent()
        }

        /// Whether the current operation remains valid.
        var isCurrent: Bool {
            lease.isCurrent
        }
    }

    /// Releases resources in the specified scope and returns the cleanup result.
    ///
    /// - Parameters:
    ///   - scope: The resource scope to release.
    ///   - taskID: The generation task identifier to finish; an empty string if there is no task.
    ///
    /// - Returns: The session identifier and retained local media after cleanup.
    typealias CleanupHandler =
        @Sendable (
            _ scope: TerminationScope,
            _ taskID: String
        ) async -> CleanupResult

    /// The handler reporting errors and invalidating stale failure callbacks.
    private let errorManager: XmaxRealtimeErrorManager

    /// The handler that releases resources for a termination scope.
    private let cleanup: CleanupHandler

    /// The operation that stops local capture before blocked cleanup finishes.
    private let stopLocalCapture: @Sendable () async -> Void

    /// The realtime state snapshot exposed to your app.
    private var state = RealtimeState(connectionState: .idle)

    /// The listener for connection and generation state changes.
    private var stateListener: RealtimeStateListener?

    /// The operation currently admitted by the lifecycle manager.
    private var activeOperation: Operation?

    /// The latest generation request, including one waiting for its predecessor's cleanup.
    private var generationRequest: GenerationRequest?

    /// The merged termination request currently being processed.
    private var termination: Termination?

    /// The number of pending or executing foreground requests, which take priority over adaptation.
    private var foregroundRequests = 0

    /// Creates a realtime lifecycle manager.
    ///
    /// - Parameters:
    ///   - errorManager: The handler that logs errors and forwards runtime failures.
    ///   - cleanup: The callback that releases resources in the specified scope.
    ///   - stopLocalCapture: Releases SDK-owned capture immediately on full termination, before waiting for operations.
    init(
        errorManager: XmaxRealtimeErrorManager,
        cleanup: @escaping CleanupHandler,
        stopLocalCapture: @escaping @Sendable () async -> Void = {}
    ) {
        self.errorManager = errorManager
        self.cleanup = cleanup
        self.stopLocalCapture = stopLocalCapture
    }

    /// The currently published realtime state.
    var currentState: RealtimeState {
        state
    }

    /// Updates the state listener and immediately reports the current state.
    ///
    /// - Parameter listener: The state callback; pass `nil` to remove the listener.
    func setStateListener(
        _ listener: RealtimeStateListener?
    ) async {
        stateListener = listener
        if let listener {
            await listener(state)
        }
    }

    /// Replaces pending generation requests while rejecting other operation conflicts.
    ///
    /// - Parameters:
    ///   - kind: The requested operation kind.
    ///   - failureScope: The cleanup scope on failure or cancellation; `nil` skips proactive cleanup.
    ///   - body: The operation body, which uses the supplied token to check validity across asynchronous work.
    ///
    /// - Returns: The result of a successful operation.
    ///
    /// - Throws: An error if an operation or cleanup already owns the lifecycle, or the operation fails or is
    ///   cancelled.
    func run<Value: Sendable>(
        kind: OperationKind,
        failureScope: TerminationScope? = nil,
        operation body: @escaping @Sendable (Token) async throws -> Value
    ) async throws -> Value {
        foregroundRequests += 1
        defer {
            foregroundRequests -= 1
        }

        if kind == .generation {
            return try await runGeneration(
                failureScope: failureScope,
                operation: body
            )
        }

        return try await runOperation(
            kind: kind,
            failureScope: failureScope,
            operation: body
        )
    }

    /// Waits for a background commit, then admits the current request under exclusive operation ownership.
    private func runOperation<Value: Sendable>(
        kind: OperationKind,
        failureScope: TerminationScope?,
        request: GenerationRequest? = nil,
        operation body: @escaping @Sendable (Token) async throws -> Value
    ) async throws -> Value {
        if let background = activeOperation, background.background {
            // Finish committing the background configuration before applying a foreground request.
            await background.waitForCompletion()
            finish(background)
        }

        try Task.checkCancellation()
        if let request, generationRequest !== request {
            throw Self.cancelledError()
        }
        guard termination == nil, activeOperation == nil,
            request != nil || generationRequest == nil
        else {
            let error = XmaxError(
                code: .invalidConfiguration,
                message: "Another realtime operation is in progress; wait for it to finish"
            )
            await errorManager.report(error)
            throw error
        }

        // An active generation request updates conditions using the shared configuration operation.
        let operationKind: OperationKind =
            kind == .generation && state.connectionState == .generating
            ? .configuration : kind
        let operation = Operation(
            kind: operationKind,
            failureScope: failureScope,
            generationRequest: request
        )
        let token = Token(lease: operation.lease)
        let task = Task {
            try await body(token)
        }

        operation.cancel = {
            task.cancel()
        }
        operation.waitForCompletion = {
            _ = try? await task.value
        }

        activeOperation = operation

        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                operation.lease.invalidate()
                task.cancel()
            }

            try Task.checkCancellation()
            try token.ensureCurrent()

            let completionState = operation.completionState
            finish(operation)
            if let completionState {
                await setState(completionState)
            }
            return value
        } catch {
            return try await handleFailure(
                error,
                operation: operation
            )
        }
    }

    /// Applies a low-priority quality adjustment when idle; skips it when busy without changing public state.
    ///
    /// - Parameter body: The transport configuration operation; check the token after asynchronous boundaries.
    ///
    /// - Returns: Whether the adjustment was admitted and completed successfully.
    ///
    /// - Throws: An error if an admitted configuration operation fails or is terminated.
    func runAdaptiveConfiguration(
        _ body: @escaping @Sendable (Token) async throws -> Void
    ) async throws -> Bool {
        guard termination == nil, activeOperation == nil,
            generationRequest == nil, foregroundRequests == 0,
            state.connectionState == .generating
        else {
            return false
        }

        let operation = Operation(
            kind: .configuration,
            failureScope: nil,
            background: true
        )
        let token = Token(lease: operation.lease)
        let task = Task {
            try await body(token)
        }

        operation.cancel = {
            task.cancel()
        }
        operation.waitForCompletion = {
            _ = try? await task.value
        }

        activeOperation = operation
        defer {
            finish(operation)
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            operation.lease.invalidate()
            task.cancel()
        }

        try token.ensureCurrent()
        return true
    }

    /// Commits state produced by the current valid operation.
    ///
    /// - Parameters:
    ///   - nextState: The state to publish.
    ///   - token: The validity token for this operation.
    ///
    /// - Throws: An error if the operation is invalid or cancelled.
    func commit(
        _ nextState: RealtimeState,
        token: Token
    ) async throws {
        try token.ensureCurrent()

        if nextState.connectionState == .preparing,
            let activeOperation, activeOperation.lease === token.lease,
            activeOperation.kind == .media
        {
            activeOperation.didBeginMediaPreparation = true
        }

        await setState(nextState)
    }

    /// Stages completion until operation ownership is released, before notifying listeners.
    func complete(
        _ nextState: RealtimeState,
        token: Token
    ) throws {
        try token.ensureCurrent()
        guard let activeOperation, activeOperation.lease === token.lease else {
            throw Self.cancelledError()
        }

        activeOperation.completionState = nextState
    }

    /// Marks media preparation as ready once the current local preview is ready.
    ///
    /// - Parameter isCurrent: The callback checking whether the preview notification belongs to the current local
    ///   media.
    func localPreviewDidBecomeReady(
        isCurrent: @Sendable () -> Bool
    ) async {
        guard state.connectionState == .preparing, isCurrent() else { return }
        await setState(RealtimeState(connectionState: .ready))
    }

    /// Disconnects realtime and waits for connection operations and resource cleanup.
    ///
    /// - Parameter reason: The disconnect reason reported with the final state.
    func disconnect(
        reason: RealtimeReason = .normal
    ) async {
        let task = await beginDisconnect(reason: reason)
        await task?.value
    }

    /// Starts connection cleanup and returns its completion task while retaining local media.
    ///
    /// - Parameter reason: The disconnect reason reported with the final state.
    ///
    /// - Returns: The connection cleanup task, or `nil` if no connection or related operation needs termination.
    func beginDisconnect(
        reason: RealtimeReason
    ) async -> Task<Void, Never>? {
        let hasConnectionOperation =
            activeOperation.map {
                TerminationScope.connection.affects($0.kind)
            } ?? false
        guard
            hasConnectionOperation || generationRequest != nil || termination != nil
                || (state.connectionState != .idle && state.connectionState != .preparing
                    && state.connectionState != .ready)
        else {
            return nil
        }
        return await requestTermination(
            .connection,
            reason: reason
        )
    }

    /// Terminates operations in scope and waits for cleanup; concurrent requests merge to the broadest scope.
    ///
    /// - Parameters:
    ///   - target: The resource scope to terminate.
    ///   - reason: The termination reason reported with the final state.
    func terminate(
        _ target: TerminationScope,
        reason: RealtimeReason = .normal
    ) async {
        let task = await requestTermination(
            target,
            reason: reason
        )
        await task.value
    }

    /// Terminates failed resources in the current lifecycle and reports the error in the final state.
    ///
    /// - Parameters:
    ///   - error: The runtime error that triggered termination.
    ///   - target: The resource scope to terminate.
    ///   - isCurrent: The callback checking whether the error belongs to the current lifecycle.
    func terminate(
        with error: XmaxError,
        target: TerminationScope,
        isCurrent: @Sendable () -> Bool = { true }
    ) async {
        guard isCurrent() else { return }
        // Late remote errors cannot override an explicit stop during cleanup; local media failure still broadens cleanup.
        if let termination, termination.target != .generation, target != .all { return }
        let task = await requestTermination(
            target,
            error: error,
            reason: .failure(error)
        )
        await task.value
    }
}

private extension XmaxRealtimeLifecycleManager {

    /// A generation request's cancellation handle and resource-completion barrier.
    final class GenerationRequest: @unchecked Sendable {

        /// Cancels the request's worker; installed before publishing the request.
        var cancel: @Sendable () -> Void = {}

        /// Protects completion and its suspended successors.
        private let lock = NSLock()

        /// Whether all work and required cleanup have completed.
        private var completed = false

        /// The successors waiting for resource ownership to become available.
        private var waiters: [CheckedContinuation<Void, Never>] = []

        /// Waits for completion even when the waiting request has been cancelled.
        func waitForCompletion() async {
            await withCheckedContinuation { continuation in
                let alreadyCompleted = lock.withLock {
                    if completed {
                        return true
                    }
                    waiters.append(continuation)
                    return false
                }

                if alreadyCompleted {
                    continuation.resume()
                }
            }
        }

        /// Releases successors after work and cleanup, before state callbacks are delivered.
        func finish() {
            let pending = lock.withLock {
                completed = true
                let pending = waiters
                waiters.removeAll()
                return pending
            }

            for waiter in pending {
                waiter.resume()
            }
        }
    }

    /// Replaces the previous generation request and waits for its resource cleanup.
    ///
    /// - Parameters:
    ///   - failureScope: The resources released if generation fails or is cancelled.
    ///   - body: The generation work guarded by its operation token.
    ///
    /// - Returns: The latest request's successful result.
    ///
    /// - Throws: An error if another operation conflicts, generation fails, or the request is cancelled.
    func runGeneration<Value: Sendable>(
        failureScope: TerminationScope?,
        operation body: @escaping @Sendable (Token) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard (termination == nil || generationRequest != nil),
            activeOperation == nil || activeOperation?.background == true
                || activeOperation?.generationRequest != nil
        else {
            let error = XmaxError(
                code: .invalidConfiguration,
                message: "Another realtime operation is in progress; wait for it to finish"
            )
            await errorManager.report(error)
            throw error
        }

        let previous = generationRequest
        let request = GenerationRequest()
        let task = Task {
            await previous?.waitForCompletion()
            defer { request.finish() }

            try Task.checkCancellation()
            return try await runOperation(
                kind: .generation,
                failureScope: failureScope,
                request: request,
                operation: body
            )
        }

        request.cancel = { task.cancel() }
        generationRequest = request
        previous?.cancel()
        defer {
            if generationRequest === request {
                generationRequest = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            request.cancel()
        }
    }

    /// Controls operation cancellation and failure cleanup through a thread-safe validity token.
    final class OperationLease: @unchecked Sendable {

        /// The lock protecting lease validity and the terminal error.
        private let lock = NSLock()

        /// Whether the operation can still commit results.
        private var valid = true

        /// The terminal error returned after the operation is invalidated.
        private var terminalError: XmaxError?

        /// The resources to release if this operation fails.
        private var storedFailureScope: TerminationScope?

        /// Creates an operation token.
        init(
            failureScope: TerminationScope?
        ) {
            storedFailureScope = failureScope
        }

        /// Whether the operation token remains valid.
        var isCurrent: Bool {
            lock.withLock { valid }
        }

        /// The first invalidating error; may be `nil` for explicit cancellation.
        var failure: XmaxError? {
            lock.withLock { terminalError }
        }

        /// The resource cleanup scope on operation failure or cancellation.
        var failureScope: TerminationScope? {
            lock.withLock { storedFailureScope }
        }

        /// Updates the resource cleanup scope on operation failure or cancellation.
        ///
        /// - Parameter scope: The resource scope to release.
        func setFailureScope(
            _ scope: TerminationScope
        ) {
            lock.withLock {
                storedFailureScope = scope
            }
        }

        /// Invalidates the operation and preserves the first termination error.
        ///
        /// - Parameter error: The invalidating error; pass `nil` for explicit cancellation.
        func invalidate(
            error: XmaxError? = nil
        ) {
            lock.withLock {
                valid = false
                if terminalError == nil {
                    terminalError = error
                }
            }
        }

        /// Checks that the token is valid and the current task has not been cancelled.
        ///
        /// - Throws: The termination or cancellation error if invalid; throws cancellation if the task is cancelled.
        func ensureCurrent() throws {
            let result = lock.withLock { (valid, terminalError) }
            guard result.0 else {
                if let error = result.1 {
                    throw error
                }
                throw Self.cancelledError()
            }
            try Task.checkCancellation()
        }

        /// Creates a realtime operation cancellation error.
        ///
        /// - Returns: The SDK error representing a cancelled realtime operation.
        private static func cancelledError() -> XmaxError {
            XmaxError(
                code: .cancelled,
                message: "Realtime operation was cancelled"
            )
        }
    }

    /// Stores the identity, cancellation control, and completion task of one realtime operation.
    final class Operation: @unchecked Sendable {

        /// The identifier distinguishing this operation from concurrent requests.
        let id = UUID()

        /// The operation kind used for admission and termination decisions.
        let kind: OperationKind

        /// Whether this is a background operation that yields to foreground requests.
        let background: Bool

        /// The generation request owning this operation, retained through rollback.
        let generationRequest: GenerationRequest?

        /// Whether this operation owns the preparation state it may roll back on failure.
        var didBeginMediaPreparation = false

        /// The final state published only after successful completion and admission release.
        var completionState: RealtimeState?

        /// The lease managing validity and failure cleanup for this operation.
        let lease: OperationLease

        /// The closure that cancels the underlying task.
        var cancel: @Sendable () -> Void = {}

        /// The closure that awaits underlying task completion before releasing its resources.
        var waitForCompletion: @Sendable () async -> Void = {}

        /// The resource cleanup task assigned to this operation.
        var terminationTask: Task<Void, Never>?

        /// Creates a realtime operation record.
        ///
        /// - Parameters:
        ///   - kind: The operation kind that determines cancellation and cleanup behavior.
        ///   - failureScope: The cleanup scope on failure or cancellation.
        ///   - background: Whether this is a low-priority background configuration operation.
        init(
            kind: OperationKind,
            failureScope: TerminationScope?,
            background: Bool = false,
            generationRequest: GenerationRequest? = nil
        ) {
            self.kind = kind
            self.background = background
            self.generationRequest = generationRequest
            lease = OperationLease(failureScope: failureScope)
        }
    }

    /// Merges concurrent termination requests and stores the cleanup scope, reason, and completion task.
    final class Termination: @unchecked Sendable {

        /// The identifier distinguishing successive termination lifecycles.
        let id = UUID()

        /// The resources to release for this termination.
        var target: TerminationScope

        /// The reason delivered to the state listener after cleanup.
        var reason: RealtimeReason

        /// The failure that triggered termination, or `nil` for an explicit request.
        var error: XmaxError?

        /// The server session identifier involved in cleanup.
        var sessionID: String?

        /// The operations that must complete before resources are released.
        var waitForOperations: [@Sendable () async -> Void] = []

        /// The shared cleanup task awaited by concurrent termination requests.
        var task: Task<Void, Never>!

        /// The shared immediate capture-stop task for full termination.
        var captureStopTask: Task<Void, Never>?

        /// Creates a resource termination record.
        init(
            target: TerminationScope,
            reason: RealtimeReason,
            error: XmaxError?
        ) {
            self.target = target
            self.reason = reason
            self.error = error
        }
    }

    /// Finishes state and resource cleanup for a failed operation, then throws the error to the caller.
    ///
    /// - Parameters:
    ///   - error: The error produced during operation execution.
    ///   - operation: The operation record that produced the error.
    ///
    /// - Returns: Never returns a result; always throws after error handling finishes.
    ///
    /// - Throws: Termination or cancellation for cancelled operations; otherwise throws the converted SDK error.
    func handleFailure<Value: Sendable>(
        _ error: any Error,
        operation: Operation
    ) async throws -> Value {
        let operationWasCancelled =
            Self.isCancellation(error) || !operation.lease.isCurrent || Task.isCancelled

        if operationWasCancelled {
            // Cancelling a configuration request does not stop generation; explicit termination still awaits cleanup.
            if (operation.kind == .configuration || operation.lease.failureScope == nil),
                operation.terminationTask == nil,
                termination == nil
            {
                finish(operation)
                if operation.didBeginMediaPreparation, state.connectionState == .preparing {
                    await setState(RealtimeState(connectionState: .idle))
                }
                throw Self.cancelledError()
            }

            let terminationTask: Task<Void, Never>
            if let assignedTask = operation.terminationTask {
                terminationTask = assignedTask
            } else if let termination {
                terminationTask = termination.task
            } else {
                let isReplacement =
                    operation.generationRequest != nil && generationRequest != nil
                    && operation.generationRequest !== generationRequest
                let scope =
                    isReplacement && state.connectionState == .connected
                    ? .generation : operation.lease.failureScope ?? TerminationScope.connection
                terminationTask = await requestTermination(
                    scope,
                    origin: operation
                )
            }

            await terminationTask.value
            finish(operation)

            if let failure = operation.lease.failure {
                throw failure
            }
            throw Self.cancelledError()
        }

        let resolvedError = XmaxError.from(error)
        if operation.kind != .configuration, let scope = operation.lease.failureScope {
            let terminationTask = await requestTermination(
                scope,
                error: resolvedError,
                reason: .failure(resolvedError),
                origin: operation
            )
            await terminationTask.value
        } else {
            finish(operation)
            if operation.didBeginMediaPreparation, state.connectionState == .preparing {
                await setState(RealtimeState(connectionState: .idle))
            }
            await errorManager.report(resolvedError)
            throw resolvedError
        }

        finish(operation)
        throw resolvedError
    }

    /// Creates or merges a termination request and cancels operations in its cleanup scope.
    ///
    /// - Parameters:
    ///   - target: The resource cleanup scope of this request.
    ///   - error: The cleanup-triggering error; pass `nil` for an explicit stop.
    ///   - reason: The reason included in the final state.
    ///   - origin: The failed operation initiating cleanup; `nil` for external termination requests.
    ///
    /// - Returns: The merged resource cleanup task.
    func requestTermination(
        _ target: TerminationScope,
        error: XmaxError? = nil,
        reason: RealtimeReason = .normal,
        origin: Operation? = nil
    ) async -> Task<Void, Never> {
        if origin == nil {
            generationRequest?.cancel()
            generationRequest = nil
        }

        let pending: Termination
        if let termination {
            pending = termination
            if target.rawValue > pending.target.rawValue {
                pending.target = target
            }
            if pending.error == nil {
                pending.error = error
            }
            if let error, pending.error == error {
                pending.reason = .failure(error)
            }
        } else {
            pending = Termination(
                target: target,
                reason: reason,
                error: error
            )
            termination = pending
            pending.task = Task { [weak self] in
                await self?.performTermination(id: pending.id)
            }
        }

        if let activeOperation,
            activeOperation !== origin,
            pending.target.affects(activeOperation.kind)
        {
            activeOperation.lease.invalidate(error: pending.error)
            activeOperation.terminationTask = pending.task
            activeOperation.cancel()
            pending.waitForOperations.append(
                activeOperation.waitForCompletion
            )
        } else if let origin {
            origin.lease.invalidate(error: error)
            origin.terminationTask = pending.task
            pending.waitForOperations.append(origin.waitForCompletion)
        }

        if pending.target == .all, pending.captureStopTask == nil {
            // Stop local capture without waiting for blocked operation or remote cleanup.
            pending.captureStopTask = Task { [stopLocalCapture] in await stopLocalCapture() }
        }
        if pending.target != .generation {
            await setState(
                RealtimeState(
                    connectionState: .disconnecting,
                    sessionID: state.sessionID,
                    reason: nil
                )
            )
        }

        return pending.task
    }

    /// Waits for operations to exit, releases resources, and publishes the completed cleanup state.
    ///
    /// - Parameter id: The termination record identifier; expired requests do not perform cleanup.
    func performTermination(
        id: UUID
    ) async {
        guard let pending = termination, pending.id == id else {
            return
        }

        while true {
            await pending.captureStopTask?.value
            let waiters = pending.waitForOperations
            pending.waitForOperations.removeAll()
            for waiter in waiters {
                await waiter()
            }

            let requestedTarget = pending.target
            let taskID = state.taskID ?? ""
            let result = await cleanup(
                requestedTarget,
                taskID
            )
            if let sessionID = result.sessionID {
                pending.sessionID = sessionID
            }

            guard pending.target == requestedTarget, pending.waitForOperations.isEmpty else {
                continue
            }

            let connectionState: RealtimeConnectionState
            if requestedTarget == .generation {
                connectionState = .connected
            } else if requestedTarget == .all {
                connectionState = .idle
            } else {
                connectionState = result.hasLocalMedia ? .ready : .idle
            }

            let finalState = RealtimeState(
                connectionState: connectionState,
                sessionID: pending.sessionID ?? state.sessionID,
                reason: requestedTarget == .generation ? nil : pending.reason
            )

            // Finish internal cleanup before notifying listeners so reentrant termination cannot be overwritten.
            if let activeOperation,
                requestedTarget.affects(activeOperation.kind)
            {
                finish(activeOperation)
            }
            let listener = state != finalState ? stateListener : nil
            state = finalState
            termination = nil
            errorManager.invalidatePendingFailures(target: requestedTarget)

            if let listener {
                await listener(finalState)
            }
            if let error = pending.error {
                await errorManager.report(error)
            }
            return
        }
    }

    /// Removes the current operation matching the specified record.
    ///
    /// - Parameter operation: The completed operation record.
    func finish(
        _ operation: Operation
    ) {
        if activeOperation?.id == operation.id {
            activeOperation = nil
        }
        if generationRequest === operation.generationRequest {
            generationRequest = nil
        }
        operation.generationRequest?.finish()
    }

    /// Updates realtime state and notifies listeners only when the state changes.
    ///
    /// - Parameter nextState: The state to publish.
    func setState(
        _ nextState: RealtimeState
    ) async {
        guard state != nextState else {
            return
        }
        state = nextState
        if let stateListener {
            await stateListener(nextState)
        }
    }

    /// Checks whether an error represents operation cancellation.
    ///
    /// - Parameter error: The error to check.
    ///
    /// - Returns: `true` for task cancellation or SDK cancellation errors.
    static func isCancellation(
        _ error: any Error
    ) -> Bool {
        error is CancellationError || (error as? XmaxError)?.code == .cancelled
    }

    /// Creates a realtime operation cancellation error.
    ///
    /// - Returns: The SDK error representing a cancelled realtime operation.
    static func cancelledError() -> XmaxError {
        XmaxError(
            code: .cancelled,
            message: "Realtime operation was cancelled"
        )
    }
}

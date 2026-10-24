import Foundation

/// Lets RTC joining proceed independently, while publication waits for usable local capture.
/// Waiters are cancellation-aware so a failed sibling cannot strand a startup task group.
actor CameraStartupGate {
    private var isReady = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func ready() {
        isReady = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async throws {
        try Task.checkCancellation()
        if isReady { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

//
//  RealtimeCreditsController.swift
//  XLab
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Combine
import Foundation
import XmaxSDK

/// Refreshes the displayed account balance independently of media and generation operations.
@MainActor
final class RealtimeCreditsController: ObservableObject {
    @Published private(set) var balance: Double?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var apiKey = ""
    private var isRunning = false
    private var requestID = UUID()
    private var polling: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private let loadBalance: @Sendable (String) async throws -> Double
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        loadBalance: @escaping @Sendable (String) async throws -> Double = { apiKey in
            let client = XmaxClient(configuration: XmaxConfiguration(apiKey: apiKey, loggerOptions: .all))
            let result = try await client.getCreditBalance()
            return result.currentBalance
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.loadBalance = loadBalance
        self.sleep = sleep
    }

    deinit {
        polling?.cancel()
        request?.cancel()
    }

    var balanceText: String {
        balance?.formatted(.number.precision(.fractionLength(0...6)).locale(Locale(identifier: "en_US"))) ?? "—"
    }

    var showsLowCreditsWarning: Bool { balance.map { $0 < 300 } ?? false }

    var help: String {
        if apiKey.isEmpty { return "Enter an API key to view remaining credits" }
        if let errorMessage {
            let status = balance == nil ? "Credits unavailable." : "Showing the last known balance."
            return "\(status) \(errorMessage) Click to open the credits page."
        }
        if isLoading { return "Refreshing remaining credits… Click to open the credits page." }
        if showsLowCreditsWarning { return "Low credits. Click to top up." }
        return "Remaining credits. Click to open the credits page."
    }

    func start(apiKey: String) {
        isRunning = true
        setAPIKey(apiKey)
        if polling == nil { startPolling() }
    }

    /// Clears another account's display immediately and debounces queries while the key is edited.
    func setAPIKey(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != apiKey else { return }
        cancelPendingRequests()
        apiKey = value
        balance = nil
        errorMessage = nil
        if isRunning { startPolling() }
    }

    func stop() {
        isRunning = false
        cancelPendingRequests()
    }

    /// Forced refreshes replace an in-flight poll; stale completions cannot overwrite the latest balance.
    func refresh(force: Bool = false) async {
        guard isRunning, !apiKey.isEmpty, force || request == nil else { return }
        request?.cancel()
        let id = UUID()
        requestID = id
        let key = apiKey
        let loadBalance = loadBalance
        isLoading = true
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let value = try await loadBalance(key)
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.balance = value
                self.errorMessage = nil
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
            guard let self, self.requestID == id else { return }
            self.isLoading = false
            self.request = nil
        }
        request = task
        await task.value
    }

    private func startPolling() {
        guard !apiKey.isEmpty else { return }
        let sleep = sleep
        polling = Task { [weak self] in
            do { try await sleep(.milliseconds(500)) } catch { return }
            while !Task.isCancelled {
                await self?.refresh()
                do { try await sleep(.seconds(5)) } catch { return }
            }
        }
    }

    private func cancelPendingRequests() {
        requestID = UUID()
        polling?.cancel()
        polling = nil
        request?.cancel()
        request = nil
        isLoading = false
    }
}

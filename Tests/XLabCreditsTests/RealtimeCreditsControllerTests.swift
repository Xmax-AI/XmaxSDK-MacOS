import Foundation
import XCTest
import XmaxSDK
@testable import XLabCredits

@MainActor
final class RealtimeCreditsControllerTests: XCTestCase {
    func testRefreshShowsFractionalCreditsAndLoadingState() async throws {
        let (fixture, started) = makeFixture(requests: 1)
        let controller = makeController(fixture)
        defer { controller.stop() }
        controller.start(apiKey: "  key-a\n")
        XCTAssertEqual(controller.balanceText, "—")

        let refresh = Task { await controller.refresh() }
        await fulfillment(of: [started[0]], timeout: 1)
        XCTAssertTrue(controller.isLoading)
        await fixture.succeed(1, balance: 1250.75)
        await refresh.value

        XCTAssertEqual(controller.balance, 1250.75)
        XCTAssertEqual(controller.balanceText, "1,250.75")
        XCTAssertFalse(controller.showsLowCreditsWarning)
        XCTAssertFalse(controller.isLoading)
        let keys = await fixture.keys
        XCTAssertEqual(keys, ["key-a"])
    }

    func testFailureKeepsLastKnownBalanceAndLowCreditWarning() async {
        let (fixture, started) = makeFixture(requests: 2)
        let controller = makeController(fixture)
        defer { controller.stop() }
        controller.start(apiKey: "key-a")
        let initial = Task { await controller.refresh() }
        await fulfillment(of: [started[0]], timeout: 1)
        await fixture.succeed(1, balance: 0)
        await initial.value
        XCTAssertEqual(controller.balanceText, "0")
        XCTAssertTrue(controller.showsLowCreditsWarning)

        let refresh = Task { await controller.refresh() }
        await fulfillment(of: [started[1]], timeout: 1)
        await fixture.fail(2)
        await refresh.value

        XCTAssertEqual(controller.balance, 0)
        XCTAssertEqual(controller.errorMessage, "Offline")
        XCTAssertTrue(controller.help.contains("last known balance"))
        XCTAssertFalse(controller.isLoading)
    }

    func testKeyChangeClearsOldBalanceAndRejectsLateResponses() async {
        let (fixture, started) = makeFixture(requests: 3)
        let controller = makeController(fixture)
        defer { controller.stop() }
        controller.start(apiKey: "key-a")
        let initial = Task { await controller.refresh() }
        await fulfillment(of: [started[0]], timeout: 1)
        await fixture.succeed(1, balance: 500)
        await initial.value
        let oldRequest = Task { await controller.refresh() }
        await fulfillment(of: [started[1]], timeout: 1)

        controller.setAPIKey("key-b")
        XCTAssertNil(controller.balance)
        XCTAssertNil(controller.errorMessage)
        let newRequest = Task { await controller.refresh() }
        await fulfillment(of: [started[2]], timeout: 1)
        await fixture.succeed(3, balance: 250)
        await newRequest.value
        await fixture.succeed(2, balance: 999)
        await oldRequest.value

        XCTAssertEqual(controller.balance, 250)
        let keys = await fixture.keys
        XCTAssertEqual(keys, ["key-a", "key-a", "key-b"])
    }

    func testStoppingIgnoresPendingResults() async {
        let (fixture, started) = makeFixture(requests: 1)
        let controller = makeController(fixture)
        controller.start(apiKey: "key-a")
        let refresh = Task { await controller.refresh() }
        await fulfillment(of: [started[0]], timeout: 1)

        controller.stop()
        await fixture.succeed(1, balance: 100)
        await refresh.value

        XCTAssertNil(controller.balance)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isLoading)
    }

    func testOrdinaryRefreshesDeduplicateAndForcedRefreshSupersedesPendingRequest() async {
        let (fixture, started) = makeFixture(requests: 2)
        let controller = makeController(fixture)
        defer { controller.stop() }
        controller.start(apiKey: "key-a")
        let original = Task { await controller.refresh() }
        await fulfillment(of: [started[0]], timeout: 1)
        await controller.refresh()
        let count = await fixture.keys.count
        XCTAssertEqual(count, 1)

        let forced = Task { await controller.refresh(force: true) }
        await fulfillment(of: [started[1]], timeout: 1)
        await fixture.succeed(2, balance: 12)
        await forced.value
        await fixture.succeed(1, balance: 100)
        await original.value

        XCTAssertEqual(controller.balance, 12)
        XCTAssertFalse(controller.isLoading)
    }

    func testEmptyKeyDoesNotQueryCredits() async {
        let (fixture, _) = makeFixture(requests: 0)
        let controller = makeController(fixture)
        defer { controller.stop() }
        controller.start(apiKey: " \n ")
        await controller.refresh(force: true)

        let keys = await fixture.keys
        XCTAssertTrue(keys.isEmpty)
        XCTAssertNil(controller.balance)
        XCTAssertFalse(controller.isLoading)
    }

    func testPollingRefreshesAfterDebounceAndSchedulesFiveSecondInterval() async {
        let (fixture, started) = makeFixture(requests: 1)
        let interval = expectation(description: "Next balance refresh scheduled")
        let controller = RealtimeCreditsController(
            loadBalance: { try await fixture.load($0) },
            sleep: { duration in
                if duration == .milliseconds(500) { return }
                XCTAssertEqual(duration, .seconds(5))
                interval.fulfill()
                try await Task.sleep(for: .seconds(60))
            }
        )
        defer { controller.stop() }

        controller.start(apiKey: "key-a")
        await fulfillment(of: [started[0]], timeout: 1)
        await fixture.succeed(1, balance: 300)
        await fulfillment(of: [interval], timeout: 1)

        XCTAssertEqual(controller.balance, 300)
        XCTAssertFalse(controller.showsLowCreditsWarning)
    }

    private func makeController(_ fixture: CreditsFixture) -> RealtimeCreditsController {
        RealtimeCreditsController(
            loadBalance: { try await fixture.load($0) },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
    }

    private func makeFixture(requests: Int) -> (CreditsFixture, [XCTestExpectation]) {
        let started = (0..<requests).map { expectation(description: "Balance request \($0 + 1)") }
        let fixture = CreditsFixture { number in
            if number <= started.count { started[number - 1].fulfill() }
        }
        return (fixture, started)
    }
}

/// Deliberately permits cancelled requests to finish so stale-account isolation is exercised.
private actor CreditsFixture {
    private(set) var keys: [String] = []
    private var pending: [Int: CheckedContinuation<Double, any Error>] = [:]
    private let onRequest: @Sendable (Int) -> Void

    init(onRequest: @escaping @Sendable (Int) -> Void) { self.onRequest = onRequest }

    func load(_ key: String) async throws -> Double {
        keys.append(key)
        let number = keys.count
        return try await withCheckedThrowingContinuation { continuation in
            pending[number] = continuation
            onRequest(number)
        }
    }

    func succeed(_ number: Int, balance: Double) {
        pending.removeValue(forKey: number)?.resume(returning: balance)
    }

    func fail(_ number: Int) {
        pending.removeValue(forKey: number)?.resume(throwing: XmaxError(code: .networkError, message: "Offline"))
    }
}

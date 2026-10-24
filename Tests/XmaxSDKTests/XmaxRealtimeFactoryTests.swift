//
//  XmaxRealtimeFactoryTests.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import XCTest
@testable import XmaxSDK

@MainActor
final class XmaxRealtimeFactoryTests: XCTestCase {
    func testDefaultAssemblySharesLifecycleAndFailureRoutingWithoutStartingServices() async throws {
        let api = FactoryAPIRecorder()
        let options = RealtimeConfiguration(model: .x2_1_1_preview_cn)
        let components = XmaxRealtimeFactory.make(options: options, apiService: api)
        let manager = XmaxRealtimeManager(options: options, components: components)
        let initial = await manager.currentState
        XCTAssertEqual(initial.connectionState, .idle)
        XCTAssertEqual(api.requests, 0)
        try await components.lifecycleManager.run(kind: .media) { token in
            try await components.lifecycleManager.complete(RealtimeState(connectionState: .ready), token: token)
        }
        let ready = await manager.currentState
        XCTAssertEqual(ready.connectionState, .ready)
        let failure = XmaxError(code: .mediaError, message: "Shared lifecycle")
        let received = expectation(description: "Factory-routed failure reaches facade")
        await manager.setStateListener { state in
            if state.reason == .failure(failure) { received.fulfill() }
        }
        components.errorManager.forward(failure, target: .all)
        await fulfillment(of: [received], timeout: 2)
        let failed = await manager.currentState
        XCTAssertEqual(failed.connectionState, .idle)
        XCTAssertEqual(failed.reason, .failure(failure))
        XCTAssertEqual(api.requests, 0)
        await manager.close()
    }

    func testConnectionQualityRetainsModelRulesAndDefersNativeEncodingUntilPublication() async throws {
        let rtc = RtcManagingStub()
        let render = RenderController(rtcManager: rtc)
        let stream = StreamController(rtcManager: rtc)
        let service = MediaServicingStub(resolvedSize: CGSize(width: 640, height: 480))
        let connection = XmaxRealtimeConnectionManager(
            sessionService: RealtimeSessionServicingStub(
                session: .init(id: "session", userID: "user", status: "ACTIVE", connection: nil, closeReason: nil)
            ),
            interactionController: InteractionController(),
            renderController: render,
            streamController: stream,
            mediaService: service
        )
        let baseline = RealtimeVideoFormat(width: 640, height: 480, fps: 30)
        let prepared = try await connection.prepareQuality(
            baseline: baseline,
            options: RealtimeConfiguration(model: .x2_1_1_preview_cn),
            configureEncoder: false,
            ensureCurrent: {}
        )
        XCTAssertEqual(prepared.configuration.minimumInputPixels, 200000)
        XCTAssertNotNil(prepared.targetSize)
        XCTAssertFalse(rtc.calls.contains { if case .configureVideoEncoding = $0 { true } else { false } })
        _ = try await connection.prepareQuality(
            baseline: baseline,
            options: RealtimeConfiguration(model: .x2_1_1_preview_cn),
            ensureCurrent: {}
        )
        XCTAssertTrue(rtc.calls.contains { if case .configureVideoEncoding = $0 { true } else { false } })
    }
}

private final class FactoryAPIRecorder: ApiServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }

    func request<Response: Decodable & Sendable>(
        _ method: ApiMethod,
        path: String,
        body: Data?,
        as responseType: Response.Type
    ) async throws -> Response {
        lock.withLock { count += 1 }
        throw XmaxError(code: .apiError, message: "Factory construction must not make network requests")
    }
}

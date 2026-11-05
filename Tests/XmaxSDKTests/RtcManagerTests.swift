//
//  RtcManagerTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import AppKit
import XCTest
@testable import XmaxSDK

final class RtcManagerTests: XCTestCase {
    func testRuntimeMicrophoneRouteIsRetainedAcrossCaptureRestarts() async throws {
        for deviceID: String? in ["usb-input", nil] {
            let selected = expectation(description: "Runtime route applied")
            let captured = expectation(description: "Runtime route reused")
            captured.expectedFulfillmentCount = 2
            let platform = RtcPlatformStub(onAudioCapture: { current in
                XCTAssertEqual(current, deviceID)
                captured.fulfill()
            }, onMicrophoneDevice: { current in
                XCTAssertEqual(current, deviceID)
                selected.fulfill()
            })
            let engines = RtcEngineManager(appID: "test", makeEngine: { _ in platform }, destroyEngine: {})
            let manager = RtcManager(engineManager: engines, microphoneDeviceID: "original")
            try await manager.initialize()
            try manager.setMicrophoneDevice(deviceID)
            try manager.startAudioCapture()
            try manager.stopAudioCapture()
            try manager.startAudioCapture()
            await fulfillment(of: [selected, captured], timeout: 1)
            await manager.destroy()
        }
    }

    func testFailedMicrophoneSwitchRestoresRouteAndRetainedSelection() async throws {
        let failure = XmaxError(code: .mediaError, message: "Device removed")
        let restored = expectation(description: "Original route restored")
        let captured = expectation(description: "Original route retained for capture")
        let platform = RtcPlatformStub(onAudioCapture: { current in
            XCTAssertEqual(current, "original")
            captured.fulfill()
        }, onMicrophoneDevice: { current in
            if current == "removed" { throw failure }
            XCTAssertEqual(current, "original")
            restored.fulfill()
        })
        let engines = RtcEngineManager(appID: "test", makeEngine: { _ in platform }, destroyEngine: {})
        let manager = RtcManager(engineManager: engines, microphoneDeviceID: "original")
        try await manager.initialize()
        XCTAssertThrowsError(try manager.setMicrophoneDevice("removed"))
        try manager.startAudioCapture()
        await fulfillment(of: [restored, captured], timeout: 1)
        await manager.destroy()
    }

    func testMicrophoneInputSelectionIsRetainedAcrossCaptureRestarts() async throws {
        for deviceID: String? in [nil, "usb-input-uid"] {
            let captured = expectation(description: "Selected input reaches audio capture")
            captured.expectedFulfillmentCount = 2
            let platform = RtcPlatformStub(onAudioCapture: { selected in
                XCTAssertEqual(selected, deviceID)
                captured.fulfill()
            })
            let engines = RtcEngineManager(
                appID: "test",
                makeEngine: { _ in platform },
                destroyEngine: {}
            )
            let manager = RtcManager(engineManager: engines, microphoneDeviceID: deviceID)
            try await manager.initialize()
            try manager.startAudioCapture()
            try manager.stopAudioCapture()
            try manager.startAudioCapture()
            await fulfillment(of: [captured], timeout: 1)
            await manager.destroy()
        }
    }

    func testRejectedMicrophoneSelectionPropagatesCaptureFailure() async throws {
        let platform = RtcPlatformStub(onAudioCapture: { _ in
            throw XmaxError(code: .mediaError, message: "Input removed")
        })
        let engines = RtcEngineManager(appID: "test", makeEngine: { _ in platform }, destroyEngine: {})
        let manager = RtcManager(engineManager: engines, microphoneDeviceID: "removed-input")
        try await manager.initialize()
        XCTAssertThrowsError(try manager.startAudioCapture()) { error in
            XCTAssertEqual((error as? XmaxError)?.code, .mediaError)
        }
        await manager.destroy()
    }

    @MainActor
    func testPreviewBindingDoesNotBlockMainThreadDuringJoinAndOnlyBindsLatestView() async throws {
        let entered = expectation(description: "Join holds control lock")
        let attached = expectation(description: "Latest preview eventually attached")
        let gate = DispatchSemaphore(value: 0)
        let room = RtcRoomStub(onJoin: {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
        })
        let first = NSView(), latest = NSView()
        let manager = RtcManager(engineManager: RtcEngineManager(
            appID: "test", makeEngine: { _ in
                RtcPlatformStub(makeRoom: { _ in room }, onPreviewAttach: { view in
                    XCTAssertTrue(view === latest)
                    attached.fulfill()
                })
            }, destroyEngine: {}
        ))
        try await manager.initialize()
        let join = Task.detached {
            try await manager.joinRoom(configuration: RoomJoinConfiguration(roomID: "room", userID: "user", token: "token"))
        }
        await fulfillment(of: [entered], timeout: 2)
        let start = ContinuousClock.now
        try manager.attachCameraPreview(to: first, contentMode: .fit, mirrored: false)
        try manager.detachCameraPreview(from: first)
        try manager.attachCameraPreview(to: latest, contentMode: .fit, mirrored: false)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
        gate.signal()
        room.emit(.joined)
        try await join.value
        await fulfillment(of: [attached], timeout: 2)
        await manager.destroy()
    }

    func testInitializeIsIdempotentAndDestroyReleasesEngine() async throws {
        let lifecycle = RtcManagerEngineLifecycleRecorder()
        let engineManager = RtcEngineManager(
            appID: "test-app-id",
            makeEngine: lifecycle.create,
            destroyEngine: lifecycle.destroy
        )
        let manager = RtcManager(engineManager: engineManager)

        try await manager.initialize()
        try await manager.initialize()

        XCTAssertEqual(lifecycle.creationCount, 1)
        XCTAssertEqual(lifecycle.destroyCount, 0)

        await manager.destroy()

        XCTAssertEqual(lifecycle.destroyCount, 1)
    }

    func testCancellingOneInitializationKeepsOtherWaitersValid() async throws {
        let lifecycle = RtcManagerEngineLifecycleRecorder()
        let engineManager = RtcEngineManager(
            appID: "test-app-id",
            makeEngine: lifecycle.create,
            destroyEngine: lifecycle.destroy
        )
        let occupiedLease = try await engineManager.acquire()
        let manager = RtcManager(engineManager: engineManager)
        let first = Task { try await manager.initialize() }
        let second = Task { try await manager.initialize() }
        for _ in 0..<100 {
            await Task.yield()
        }
        first.cancel()
        await engineManager.release(occupiedLease)

        do {
            try await first.value
            XCTFail("Expected cancelled initialization to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        try await second.value
        XCTAssertEqual(lifecycle.creationCount, 2)
        XCTAssertEqual(lifecycle.destroyCount, 1)

        try await manager.initialize()
        XCTAssertEqual(lifecycle.creationCount, 2)
        await manager.destroy()
        XCTAssertEqual(lifecycle.destroyCount, 2)
    }

    func testCancellationDuringEngineCreationReturnsLease() async throws {
        let lifecycle = RtcManagerEngineLifecycleRecorder()
        let creationStarted = expectation(description: "Engine creation started")
        let creationGate = DispatchSemaphore(value: 0)
        let engineManager = RtcEngineManager(
            appID: "test-app-id",
            makeEngine: { appID in
                let engine = lifecycle.create(appID: appID)
                if lifecycle.creationCount == 1 {
                    creationStarted.fulfill()
                    _ = creationGate.wait(timeout: .now() + 3)
                }
                return engine
            },
            destroyEngine: lifecycle.destroy
        )
        let manager = RtcManager(engineManager: engineManager)
        let initialization = Task { try await manager.initialize() }
        await fulfillment(of: [creationStarted], timeout: 2)
        initialization.cancel()
        creationGate.signal()

        do {
            try await initialization.value
            XCTFail("Expected cancelled initialization to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
        XCTAssertEqual(lifecycle.destroyCount, 1)

        try await manager.initialize()
        XCTAssertEqual(lifecycle.creationCount, 2)
        await manager.destroy()
        XCTAssertEqual(lifecycle.destroyCount, 2)
    }

    func testMediaOperationRequiresInitializedEngine() {
        let manager = RtcManager(
            engineManager: RtcEngineManager(
                appID: "test-app-id",
                makeEngine: { _ in RtcPlatformStub() },
                destroyEngine: {}
            )
        )

        XCTAssertThrowsError(
            try manager.configureVideoEncoding(
                VideoEncodingConfiguration(
                    width: 720,
                    height: 1280,
                    frameRate: 24
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .rtcError,
                    message: "RTC engine is not initialized"
                )
            )
        }
    }

    func testVideoEncodingRejectsInvalidFormatBeforeEngineAccess() {
        let manager = RtcManager()

        XCTAssertThrowsError(
            try manager.configureVideoEncoding(
                VideoEncodingConfiguration(width: 0, height: 1280, frameRate: 24)
            )
        ) { error in
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .invalidConfiguration,
                    message: "Video width, height, and frame rate must be positive"
                )
            )
        }
    }

    func testJoinAllowsEmptyTokenButRequiresRoomAndUserIDs() async {
        let manager = RtcManager()

        do {
            try await manager.joinRoom(
                configuration: RoomJoinConfiguration(
                    roomID: "",
                    userID: "user",
                    token: ""
                )
            )
            XCTFail("Expected an empty room ID to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }

        do {
            try await manager.joinRoom(
                configuration: RoomJoinConfiguration(
                    roomID: "room",
                    userID: "",
                    token: ""
                )
            )
            XCTFail("Expected an empty user ID to fail")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidConfiguration)
        }

        do {
            try await manager.joinRoom(
                configuration: RoomJoinConfiguration(
                    roomID: "room",
                    userID: "user",
                    token: ""
                )
            )
            XCTFail("Expected an uninitialized engine to fail")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .rtcError,
                    message: "RTC engine is not initialized"
                )
            )
        }
    }

}

private final class RtcManagerEngineLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0
    private var destructions = 0

    var creationCount: Int {
        lock.withLock { creations }
    }

    var destroyCount: Int {
        lock.withLock { destructions }
    }

    func create(appID: String) -> (any RtcPlatform)? {
        lock.withLock {
            creations += 1
        }
        return RtcPlatformStub()
    }

    func destroy() {
        lock.withLock {
            destructions += 1
        }
    }
}

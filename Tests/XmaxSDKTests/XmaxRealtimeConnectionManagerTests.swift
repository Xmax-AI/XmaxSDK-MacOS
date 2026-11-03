//
//  XmaxRealtimeConnectionManagerTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import XCTest
@testable import XmaxSDK

@MainActor
final class XmaxRealtimeConnectionManagerTests: XCTestCase {
    func testConnectCreatesSessionJoinsRoomAndPublishesLocalMedia() async throws {
        let rtcManager = RtcManagingStub()
        let sessionService = RealtimeSessionServicingStub(session: session)
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: sessionService
        )
        let format = RealtimeVideoFormat(
            width: 720,
            height: 1280,
            fps: 24
        )

        let stream = try await components.manager.connect(
            model: .x2_1,
            videoFormat: format,
            includeLocalAudio: true,
            isCurrent: { true },
            onHeartbeatFailure: { _, _ in }
        )

        XCTAssertEqual(stream.id, StreamID.remote.rawValue)
        XCTAssertEqual(stream.videoTrack?.id, "bot-user")
        XCTAssertEqual(stream.videoTrack?.videoFormat, format)
        let currentSessionID = await components.manager.currentSessionID
        XCTAssertEqual(currentSessionID, "session-id")
        XCTAssertEqual(
            rtcManager.calls,
            [
                .joinRoom(
                    RoomJoinConfiguration(
                        roomID: "room-id",
                        userID: "user-id",
                        token: "room-token"
                    )
                ),
                .publishLocalVideo,
                .publishLocalAudio
            ]
        )
        XCTAssertEqual(
            sessionService.calls,
            [
                .createSession(.x2_1)
            ]
        )
        let track = try XCTUnwrap(stream.videoTrack)
        XCTAssertNotNil(VideoRenderRegistry.binding(for: track))

        _ = try await components.manager.disconnect()
    }

    func testCommittedGeneratingStartsHeartbeatOnlyOnceAndStaleSessionsCannotRestartIt() async throws {
        let service = RealtimeSessionServicingStub(session: session)
        let components = makeManager(sessionService: service)
        let manager = components.manager
        _ = try await manager.connect(
            model: .x2_1, videoFormat: videoFormat, includeLocalAudio: false,
            isCurrent: { true }, onHeartbeatFailure: { _, _ in }
        )
        XCTAssertEqual(service.calls, [.createSession(.x2_1)])
        let lifecycle = XmaxRealtimeLifecycleManager(
            errorManager: XmaxRealtimeErrorManager(),
            cleanup: { _, _ in .init() },
            onStateChanged: { state in
                if state.connectionState == .generating, let sessionID = state.sessionID {
                    await manager.startHeartbeat(sessionID: sessionID)
                }
            }
        )
        try await lifecycle.run(kind: .generation) { token in
            try await lifecycle.complete(
                RealtimeState(connectionState: .generating, sessionID: "session-id", taskID: "task"),
                token: token
            )
            XCTAssertEqual(service.calls, [.createSession(.x2_1)], "Staged completion cannot start heartbeats")
        }
        await manager.startHeartbeat(sessionID: "session-id")
        let heartbeats = service.calls.compactMap { call -> Int? in
            if case .startHeartbeat("session-id", let seconds) = call { return seconds }
            return nil
        }
        XCTAssertEqual(heartbeats.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(heartbeats.first), 0)
        _ = try await manager.disconnect()
        let calls = service.calls
        await manager.startHeartbeat(sessionID: "session-id")
        XCTAssertEqual(service.calls, calls)
    }

    func testRemoteTrackBindingRendersSelectedRtcStream() async throws {
        let rtcManager = RtcManagingStub()
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: RealtimeSessionServicingStub(session: session)
        )
        let stream = try await components.manager.connect(
            model: .x2_1,
            videoFormat: videoFormat,
            includeLocalAudio: false,
            isCurrent: { true },
            onHeartbeatFailure: { _, _ in }
        )
        let view = XmaxRealtimeVideoView(
            track: stream.videoTrack,
            videoContentMode: .fit
        )
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        defer {
            view.removeFromSuperview()
            window.close()
        }
        let remoteStream = RemoteStream(
            roomID: "room-id",
            userID: "bot-user"
        )

        try components.renderController.setRemoteStream(remoteStream)

        XCTAssertEqual(
            rtcManager.calls.last,
            .setRemoteVideoFrameListener(remoteStream, enabled: true)
        )
        _ = try await components.manager.disconnect()
        XCTAssertTrue(
            rtcManager.calls.contains(
                .setRemoteVideoFrameListener(
                    remoteStream,
                    enabled: false
                )
            )
        )
    }

    func testDisconnectStopsHeartbeatAndReleasesConnectionResources() async throws {
        let rtcManager = RtcManagingStub()
        let sessionService = RealtimeSessionServicingStub(session: session)
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: sessionService
        )
        let stream = try await components.manager.connect(
            model: .x2_1,
            videoFormat: videoFormat,
            includeLocalAudio: true,
            isCurrent: { true },
            onHeartbeatFailure: { _, _ in }
        )
        let track = try XCTUnwrap(stream.videoTrack)

        let disconnectedSessionID = try await components.manager.disconnect()
        let currentSessionID = await components.manager.currentSessionID

        XCTAssertEqual(disconnectedSessionID, "session-id")
        XCTAssertEqual(currentSessionID, "")
        XCTAssertNil(VideoRenderRegistry.binding(for: track))
        XCTAssertEqual(
            sessionService.calls,
            [
                .createSession(.x2_1),
                .stopHeartbeat,
                .closeSession("session-id")
            ]
        )
        XCTAssertEqual(
            Array(rtcManager.calls.suffix(3)),
            [.unpublishLocalAudio, .unpublishLocalVideo, .leaveRoom]
        )
    }

    func testFailedServerClosureStillReleasesRTCBeforeReportingError() async throws {
        let rtc = RtcManagingStub()
        let failure = XmaxError(code: .networkError, message: "Session closure failed")
        let service = RealtimeSessionServicingStub(session: session, closeError: failure)
        let components = makeManager(rtcManager: rtc, sessionService: service)
        let remote = try await components.manager.connect(
            model: .x2_1, videoFormat: videoFormat, includeLocalAudio: true,
            isCurrent: { true }, onHeartbeatFailure: { _, _ in }
        )
        do {
            _ = try await components.manager.disconnect()
            XCTFail("The server close error must remain observable")
        } catch {
            XCTAssertEqual(error as? XmaxError, failure)
        }
        XCTAssertEqual(Array(rtc.calls.suffix(3)), [.unpublishLocalAudio, .unpublishLocalVideo, .leaveRoom])
        XCTAssertNil(VideoRenderRegistry.binding(for: try XCTUnwrap(remote.videoTrack)))
        let currentSessionID = await components.manager.currentSessionID
        XCTAssertEqual(currentSessionID, "")
        let calls = service.calls
        _ = try await components.manager.disconnect()
        XCTAssertEqual(service.calls.filter { if case .closeSession = $0 { true } else { false } },
                       calls.filter { if case .closeSession = $0 { true } else { false } })
    }

    func testServerCloseAndRTCLeaveProgressIndependently() async throws {
        let serverPause = AsyncStream<Void>.makeStream()
        let rtcPause = AsyncStream<Void>.makeStream()
        defer { serverPause.continuation.finish(); rtcPause.continuation.finish() }
        let serverEntered = expectation(description: "Server close starts without waiting for RTC")
        let rtcEntered = expectation(description: "RTC leave starts without waiting for server close")
        let service = RealtimeSessionServicingStub(session: session, closeHandler: {
            serverEntered.fulfill()
            var iterator = serverPause.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        let rtc = RtcManagingStub(leaveRoomHandler: {
            rtcEntered.fulfill()
            var iterator = rtcPause.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        let components = makeManager(rtcManager: rtc, sessionService: service)
        _ = try await components.manager.connect(
            model: .x2_1, videoFormat: videoFormat, includeLocalAudio: false,
            isCurrent: { true }, onHeartbeatFailure: { _, _ in }
        )
        var completed = false
        let closing = Task {
            let result = try await components.manager.disconnect()
            completed = true
            return result
        }
        await fulfillment(of: [serverEntered, rtcEntered], timeout: 2)
        XCTAssertFalse(completed, "Disconnect must await both cleanup branches")
        serverPause.continuation.finish()
        rtcPause.continuation.finish()
        let closedSessionID = try await closing.value
        XCTAssertEqual(closedSessionID, "session-id")
        XCTAssertTrue(completed)
    }

    func testConnectionFailureRollsBackRoomAndClosesSession() async {
        let publicationError = XmaxError(
            code: .rtcError,
            message: "publish failed"
        )
        let rtcManager = RtcManagingStub(
            publishLocalVideoError: publicationError
        )
        let sessionService = RealtimeSessionServicingStub(session: session)
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: sessionService
        )

        do {
            _ = try await components.manager.connect(
                model: .x2_1,
                videoFormat: videoFormat,
                targetSize: CGSize(width: 702, height: 1242),
                includeLocalAudio: false,
                isCurrent: { true },
                onHeartbeatFailure: { _, _ in }
            )
            XCTFail("Expected local publication to fail")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                publicationError
            )
        }

        let targetSize = await components.manager.currentTargetSize
        XCTAssertNil(targetSize)

        XCTAssertEqual(
            sessionService.calls,
            [
                .createSession(.x2_1),
                .stopHeartbeat,
                .closeSession("session-id")
            ]
        )
        XCTAssertEqual(
            rtcManager.calls,
            [
                .joinRoom(
                    RoomJoinConfiguration(
                        roomID: "room-id",
                        userID: "user-id",
                        token: "room-token"
                    )
                ),
                .publishLocalVideo,
                .leaveRoom
            ]
        )
    }

    func testCancelledConnectionClosesLateSessionWithoutJoiningRoom() async {
        let rtcManager = RtcManagingStub()
        let sessionService = RealtimeSessionServicingStub(session: session)
        let components = makeManager(
            rtcManager: rtcManager,
            sessionService: sessionService
        )

        do {
            _ = try await components.manager.connect(
                model: .x2_1,
                videoFormat: videoFormat,
                includeLocalAudio: false,
                isCurrent: { false },
                onHeartbeatFailure: { _, _ in }
            )
            XCTFail("Expected stale connection to be cancelled")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .cancelled,
                    message: "Realtime connection was cancelled"
                )
            )
        }

        XCTAssertTrue(rtcManager.calls.isEmpty)
        XCTAssertEqual(
            sessionService.calls,
            [
                .createSession(.x2_1),
                .closeSession("session-id")
            ]
        )
    }

    func testUpdatingRemoteVideoFormatUpdatesActiveTrack() async throws {
        let components = makeManager(
            sessionService: RealtimeSessionServicingStub(session: session)
        )
        let stream = try await components.manager.connect(
            model: .x2_1,
            videoFormat: videoFormat,
            includeLocalAudio: false,
            isCurrent: { true },
            onHeartbeatFailure: { _, _ in }
        )
        let updatedFormat = RealtimeVideoFormat(
            width: 540,
            height: 960,
            fps: 15
        )

        await components.manager.updateRemoteVideoFormat(updatedFormat)

        XCTAssertEqual(stream.videoTrack?.videoFormat, updatedFormat)
        _ = try await components.manager.disconnect()
    }
}

private extension XmaxRealtimeConnectionManagerTests {
    struct Components {
        let manager: XmaxRealtimeConnectionManager
        let renderController: RenderController
    }

    var session: RealtimeSession {
        RealtimeSession(
            id: "session-id",
            userID: "user-id",
            status: "ACTIVE",
            connection: RealtimeSessionConnection(
                roomID: "room-id",
                userID: "user-id",
                token: "room-token",
                botName: "bot-user"
            ),
            closeReason: nil
        )
    }

    var videoFormat: RealtimeVideoFormat {
        RealtimeVideoFormat(width: 720, height: 1280, fps: 24)
    }

    func makeManager(
        rtcManager: RtcManagingStub = RtcManagingStub(),
        sessionService: RealtimeSessionServicingStub
    ) -> Components {
        let renderController = RenderController(
            rtcManager: rtcManager
        )
        let streamController = StreamController(
            rtcManager: rtcManager
        )
        return Components(
            manager: XmaxRealtimeConnectionManager(
                sessionService: sessionService,
                interactionController: InteractionController(),
                renderController: renderController,
                streamController: streamController
            ),
            renderController: renderController
        )
    }
}

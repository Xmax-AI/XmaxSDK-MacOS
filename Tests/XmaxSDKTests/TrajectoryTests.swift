//
//  TrajectoryTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AppKit
import CoreMedia
import XCTest
@testable import XmaxSDK

@MainActor
final class TrajectoryTests: XCTestCase {
    func testTopLeftCoordinatesStayTopLeftWithAndWithoutDisplayMirroring() async throws {
        let recorder = TrajectoryFrameRecorder()
        let setup = makeOverlay(listener: { await recorder.append($0) })
        defer { setup.window.close() }
        for mirrored in [false, true] {
            setup.overlay.configure(contentMode: .fit, mirrored: mirrored, requested: true)
        setup.overlay.setResolvedMediaSize(CGSize(width: 200, height: 200))
            setup.overlay.mouseDown(with: event(.leftMouseDown, x: 4, y: 6, in: setup.overlay))
            await drain()
            let last = await recorder.last()
            let frame = try XCTUnwrap(last)
            let mapped = try XCTUnwrap(InteractionCoordinateMapper.map(frame.points[0],
                viewportSize: frame.viewportSize, resolvedMediaSize: CGSize(width: 200, height: 200), contentMode: frame.contentMode))
            XCTAssertEqual(mapped.x, 0.02, accuracy: 0.0001)
            XCTAssertEqual(mapped.y, 0.03, accuracy: 0.0001)
            let visual = try XCTUnwrap(setup.renderer.began.last)
            XCTAssertEqual(visual.normalizedLocation.x, mapped.x, accuracy: 0.0001)
            XCTAssertEqual(visual.normalizedLocation.y, mapped.y, accuracy: 0.0001)
            setup.overlay.mouseUp(with: event(.leftMouseUp, x: 4, y: 6, in: setup.overlay))
        }
    }

    func testMirroredLeftEdgeRemainsInsideFitMediaAndFillUsesCroppedCoordinates() async throws {
        let recorder = TrajectoryFrameRecorder()
        let setup = makeOverlay(listener: { await recorder.append($0) })
        defer { setup.window.close() }
        setup.overlay.configure(contentMode: .fit, mirrored: true, requested: true)
        setup.overlay.setResolvedMediaSize(CGSize(width: 400, height: 200))
        setup.overlay.mouseDown(with: event(.leftMouseDown, x: 0, y: 100, in: setup.overlay))
        await drain()
        let last = await recorder.last()
        let frame = try XCTUnwrap(last)
        let mapped = try XCTUnwrap(InteractionCoordinateMapper.map(frame.points[0],
            viewportSize: frame.viewportSize, resolvedMediaSize: CGSize(width: 400, height: 200), contentMode: .fit))
        XCTAssertEqual(mapped.x, 0, accuracy: 0.001)
        setup.overlay.configure(contentMode: .fill, mirrored: false, requested: true)
        setup.overlay.setResolvedMediaSize(CGSize(width: 400, height: 200))
        setup.overlay.mouseDown(with: event(.leftMouseDown, x: 0, y: 100, in: setup.overlay))
        XCTAssertEqual(try XCTUnwrap(setup.renderer.began.last).normalizedLocation.x, 0.25, accuracy: 0.001)
    }

    func testRegistryReplacementInvalidatesOldBindingsAndLocalTracksHaveNoCapability() {
        let setup = makeOverlay()
        defer { setup.window.close() }
        let track = RealtimeVideoTrack(id: "same-string-id")
        let other = RealtimeVideoTrack(id: "same-string-id")
        XCTAssertNil(TrajectoryRegistry.binding(for: other))
        TrajectoryRegistry.register(track, binding: setup.binding)
        setup.overlay.mouseDown(with: event(.leftMouseDown, x: 70, y: 70, in: setup.overlay))
        let replacement = TrajectoryBinding(listener: { _ in }, resolvedMediaSize: CGSize(width: 400, height: 200))
        TrajectoryRegistry.register(track, binding: replacement)
        XCTAssertEqual(setup.renderer.ended.count, 1)
        setup.binding.update(enabled: true)
        setup.binding.attach(to: setup.overlay)
        setup.overlay.mouseDown(with: event(.leftMouseDown, x: 70, y: 70, in: setup.overlay))
        XCTAssertEqual(setup.renderer.began.count, 1)
        XCTAssertTrue(TrajectoryRegistry.binding(for: track) === replacement)
        XCTAssertNil(TrajectoryRegistry.binding(for: other))
        TrajectoryRegistry.unregister(track)
    }

    func testHitTestingKeepsCustomRendererPassiveAndWindowFocusLossCancelsDrag() {
        let setup = makeOverlay()
        defer { setup.window.close() }
        // Coordinates for hitTest are in the superview; the effect view must never steal the event.
        let inside = setup.overlay.convert(CGPoint(x: 70, y: 70), to: setup.overlay.superview)
        let blackBar = setup.overlay.convert(CGPoint(x: 70, y: 10), to: setup.overlay.superview)
        XCTAssertTrue(setup.overlay.hitTest(inside) === setup.overlay)
        XCTAssertNil(setup.overlay.hitTest(blackBar))
        setup.overlay.mouseDown(with: event(.leftMouseDown, x: 70, y: 70, in: setup.overlay))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: setup.window)
        XCTAssertEqual(setup.renderer.ended.count, 1)
        setup.overlay.mouseDragged(with: event(.leftMouseDragged, x: 80, y: 80, in: setup.overlay))
        XCTAssertTrue(setup.renderer.moved.isEmpty)
        setup.binding.update(enabled: false)
        XCTAssertNil(setup.overlay.hitTest(inside))
    }

    func testDragKeepsStableIdentityAndSendsDisplayedCoordinates() async throws {
        let recorder = TrajectoryFrameRecorder()
        let setup = makeOverlay(listener: { await recorder.append($0) })
        defer { setup.window.close() }
        setup.overlay.configure(contentMode: .fit, mirrored: true, requested: true)
        setup.overlay.setResolvedMediaSize(CGSize(width: 400, height: 200))
        setup.overlay.mouseDown(with: event(.leftMouseDown, x: 50, y: 75, in: setup.overlay))
        await drain()
        let first = try XCTUnwrap(setup.renderer.began.last)
        XCTAssertEqual(first.normalizedLocation.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(first.normalizedLocation.y, 0.25, accuracy: 0.001)
        let frames = await recorder.frames
        let frame = try XCTUnwrap(frames.first)
        let mapped = try XCTUnwrap(InteractionCoordinateMapper.map(frame.points[0],
            viewportSize: frame.viewportSize, resolvedMediaSize: CGSize(width: 400, height: 200), contentMode: frame.contentMode))
        XCTAssertEqual(mapped.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 0.25, accuracy: 0.001)
        setup.overlay.mouseDragged(with: event(.leftMouseDragged, x: 150, y: 125, in: setup.overlay))
        XCTAssertEqual(setup.renderer.moved.last?.id, first.id)
        XCTAssertEqual(setup.renderer.moved.last?.location, CGPoint(x: 150, y: 125))
        setup.overlay.mouseUp(with: event(.leftMouseUp, x: 150, y: 125, in: setup.overlay))
        XCTAssertEqual(setup.renderer.ended.last, first.id)
        await drain()
        let last = await recorder.last()
        let final = try XCTUnwrap(last)
        XCTAssertEqual(final.points[0], CGPoint(x: 150, y: 125))
    }

    func testFitRejectsBlackBarsAndDragClampsAtVisibleEdge() async throws {
        let recorder = TrajectoryFrameRecorder()
        let setup = makeOverlay(listener: { await recorder.append($0) })
        defer { setup.window.close() }
        setup.overlay.mouseDown(with: event(.leftMouseDown, x: 50, y: 10, in: setup.overlay))
        XCTAssertTrue(setup.renderer.began.isEmpty)
        setup.overlay.mouseDown(with: event(.leftMouseDown, x: 50, y: 75, in: setup.overlay))
        setup.overlay.mouseDragged(with: event(.leftMouseDragged, x: 500, y: -50, in: setup.overlay))
        XCTAssertEqual(setup.renderer.moved.last?.location.y, 50)
        XCTAssertLessThan(try XCTUnwrap(setup.renderer.moved.last?.location.x), 200)
        setup.overlay.mouseUp(with: event(.leftMouseUp, x: 500, y: -50, in: setup.overlay))
        await drain()
        let last = await recorder.last()
        let frame = try XCTUnwrap(last)
        XCTAssertNotNil(InteractionCoordinateMapper.map(frame.points[0], viewportSize: frame.viewportSize,
            resolvedMediaSize: CGSize(width: 400, height: 200), contentMode: .fit))
    }

    func testBindingTransferAndInvalidationRejectOldViewAndQueuedSamples() async {
        let recorder = TrajectoryFrameRecorder()
        let first = makeOverlay(listener: { await recorder.append($0) })
        let second = makeOverlay()
        defer { first.window.close(); second.window.close() }
        first.overlay.mouseDown(with: event(.leftMouseDown, x: 70, y: 70, in: first.overlay))
        // Invalidate before the asynchronous delivery can run.
        first.binding.update(enabled: false)
        await drain()
        let count = await recorder.frames.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(first.renderer.ended.count, 1)
        first.binding.update(enabled: true)
        first.binding.attach(to: second.overlay)
        first.binding.detach(from: first.overlay)
        first.overlay.mouseDown(with: event(.leftMouseDown, x: 70, y: 70, in: first.overlay))
        XCTAssertEqual(first.renderer.began.count, 1)
        second.overlay.mouseDown(with: event(.leftMouseDown, x: 80, y: 80, in: second.overlay))
        await drain()
        XCTAssertEqual(second.renderer.began.count, 1)
        first.binding.invalidate()
        first.binding.attach(to: second.overlay)
        second.overlay.mouseDown(with: event(.leftMouseDown, x: 80, y: 80, in: second.overlay))
        XCTAssertEqual(second.renderer.began.count, 1)
    }

    func testResizeDisableRendererReplacementAndWindowDetachCancelGesture() {
        let setup = makeOverlay()
        defer { setup.window.close() }
        func begin() { setup.overlay.mouseDown(with: event(.leftMouseDown, x: 70, y: 70, in: setup.overlay)) }
        begin()
        setup.overlay.frame.size.width = 240
        setup.overlay.layout()
        XCTAssertEqual(setup.renderer.ended.count, 1)
        begin()
        setup.overlay.configure(contentMode: .fit, mirrored: false, requested: false)
        setup.overlay.setResolvedMediaSize(CGSize(width: 400, height: 200))
        XCTAssertEqual(setup.renderer.ended.count, 2)
        begin()
        XCTAssertEqual(setup.renderer.began.count, 2)
        setup.overlay.configure(contentMode: .fit, mirrored: false, requested: true)
        setup.overlay.setResolvedMediaSize(CGSize(width: 400, height: 200))
        begin()
        let replacement = RecordingTrajectoryRenderer()
        setup.overlay.setRenderer(replacement)
        XCTAssertEqual(setup.renderer.ended.count, 3)
        begin()
        setup.overlay.removeFromSuperview()
        XCTAssertEqual(replacement.ended.count, 1)
        XCTAssertGreaterThan(replacement.resetCount, 0)
    }

    func testViewAndTaskReadinessGateInteraction() async throws {
        let rtc = RtcManagingStub()
        let render = RenderController(rtcManager: rtc)
        let track = RealtimeVideoTrack(id: "remote", videoFormat: RealtimeVideoFormat(width: 4, height: 4, fps: 30))
        let recorder = TrajectoryFrameRecorder()
        render.registerRemoteTrack(track, resolvedMediaSize: CGSize(width: 4, height: 4), interactionListener: { await recorder.append($0) })
        let renderer = RecordingTrajectoryRenderer()
        let video = XmaxRealtimeVideoView(track: track, videoContentMode: .fit)
        video.trajectoryRenderer = renderer
        let window = makeWindow(content: video)
        defer { window.close() }
        let overlay = try XCTUnwrap(video.subviews.compactMap { $0 as? TrajectoryOverlayView }.first)
        overlay.layout()
        let press = event(.leftMouseDown, x: 50, y: 50, in: overlay)
        overlay.mouseDown(with: press)
        XCTAssertTrue(renderer.began.isEmpty)
        try render.setRemoteStream(RemoteStream(roomID: "room", userID: "bot"))
        try rtc.emitRemoteVideoFrame()
        try await render.waitUntilRemoteFrameReady()
        overlay.mouseDown(with: press)
        XCTAssertTrue(renderer.began.isEmpty, "Frames alone cannot enable an unconfirmed task")
        render.setInteractionEnabled(true)
        overlay.mouseDown(with: press)
        XCTAssertEqual(renderer.began.count, 1)
        await drain()
        let recorded = await recorder.snapshot()
        XCTAssertFalse(recorded.isEmpty)
        render.setInteractionEnabled(false)
        XCTAssertEqual(renderer.ended.count, 1)
        try rtc.emitRemoteVideoFrame(presentationTimeStamp: CMTime(value: 1, timescale: 30))
        await drain()
        overlay.mouseDown(with: press)
        XCTAssertEqual(renderer.began.count, 1, "Late frames must not revive a stopped task")
        try await render.resetRemoteTrack(track)
        XCTAssertNil(TrajectoryRegistry.binding(for: track))
        video.track = RealtimeVideoTrack(id: "local")
        XCTAssertFalse(video.subviews.contains { $0 is TrajectoryOverlayView })
    }

    func testStationaryPressSamplesAtBoundedRateAndStopsOnMouseUp() async throws {
        let recorder = TrajectoryFrameRecorder()
        let setup = makeOverlay(listener: { await recorder.append($0) })
        defer { setup.window.close() }
        setup.overlay.mouseDown(with: event(.leftMouseDown, x: 60, y: 60, in: setup.overlay))
        for index in 0..<300 {
            setup.overlay.mouseDragged(with: event(.leftMouseDragged, x: 60 + CGFloat(index % 80), y: 80, in: setup.overlay))
        }
        try await Task.sleep(for: .milliseconds(140))
        let during = await recorder.frames.count
        XCTAssertGreaterThanOrEqual(during, 2)
        XCTAssertLessThan(during, 10, "High-rate mouse events must not become network events")
        setup.overlay.mouseUp(with: event(.leftMouseUp, x: 100, y: 80, in: setup.overlay))
        await drain()
        let after = await recorder.frames.count
        try await Task.sleep(for: .milliseconds(100))
        let stopped = await recorder.count()
        XCTAssertEqual(stopped, after)
    }

    func testReturnFrameAspectChangesKeepResolvedMediaMappingAndActiveGesture() async throws {
        let rtc = RtcManagingStub()
        let render = RenderController(rtcManager: rtc)
        let track = RealtimeVideoTrack(id: "result", videoFormat: RealtimeVideoFormat(width: 400, height: 200, fps: 30))
        let basis = CGSize(width: 400, height: 200)
        let recorder = TrajectoryFrameRecorder()
        render.registerRemoteTrack(track, resolvedMediaSize: basis, interactionListener: { await recorder.append($0) })
        let renderer = RecordingTrajectoryRenderer()
        let video = XmaxRealtimeVideoView(track: track, videoContentMode: .fit)
        video.trajectoryRenderer = renderer
        let window = makeWindow(content: video)
        defer { window.close() }
        let overlay = try XCTUnwrap(video.subviews.compactMap { $0 as? TrajectoryOverlayView }.first)
        overlay.layout()
        try render.setRemoteStream(RemoteStream(roomID: "room", userID: "bot"))
        render.setInteractionEnabled(true)
        try rtc.emitRemoteVideoFrame(width: 8, height: 8)
        try await render.waitUntilRemoteFrameReady()
        overlay.mouseDown(with: event(.leftMouseDown, x: 50, y: 25, in: overlay))
        XCTAssertTrue(renderer.began.isEmpty, "Fit margins follow the resolved media basis")
        overlay.mouseDown(with: event(.leftMouseDown, x: 50, y: 75, in: overlay))
        let began = try XCTUnwrap(renderer.began.last)
        XCTAssertEqual(began.normalizedLocation.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(began.normalizedLocation.y, 0.25, accuracy: 0.001)
        let displayed = expectation(description: "Changed return aspect is displayed")
        video.frameDisplayHandler = { displayed.fulfill() }
        try rtc.emitRemoteVideoFrame(width: 4, height: 8, presentationTimeStamp: CMTime(value: 1, timescale: 30))
        await fulfillment(of: [displayed], timeout: 2)
        video.frameDisplayHandler = nil
        XCTAssertTrue(renderer.ended.isEmpty, "Return dimensions must not invalidate the active gesture")
        overlay.mouseDragged(with: event(.leftMouseDragged, x: 150, y: 125, in: overlay))
        overlay.mouseUp(with: event(.leftMouseUp, x: 150, y: 125, in: overlay))
        await drain()
        let frames = await recorder.snapshot()
        let last = try XCTUnwrap(frames.last)
        let mapped = try XCTUnwrap(InteractionCoordinateMapper.map(
            try XCTUnwrap(last.points.last), viewportSize: last.viewportSize,
            resolvedMediaSize: basis, contentMode: last.contentMode
        ))
        XCTAssertEqual(mapped.x, 0.75, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 0.75, accuracy: 0.001)
        XCTAssertEqual(renderer.moved.last?.id, began.id)
        XCTAssertEqual(renderer.ended, [began.id])
        try await render.resetRemoteTrack(track)
    }

    func testDualVideoInteractionInitializerAndTrackChangesRetainTheSetting() {
        let local = RealtimeVideoTrack(id: "local")
        let remote = RealtimeVideoTrack(id: "remote")
        let view = XmaxRealtimeDualVideoView(
            localTrack: local, remoteTrack: remote, videoContentMode: .fit, isInteractionEnabled: false
        )
        XCTAssertFalse(view.isInteractionEnabled)
        XCTAssertFalse((view.subviews.last as? XmaxRealtimeVideoView)?.isInteractionEnabled ?? true)
        view.remoteTrack = nil
        view.remoteTrack = remote
        XCTAssertFalse(view.isInteractionEnabled)
        view.isInteractionEnabled = true
        XCTAssertTrue(view.isInteractionEnabled)
        XCTAssertTrue(XmaxRealtimeDualVideoView().isInteractionEnabled)
        view.remoteTrack = nil
        view.localTrack = nil
    }

    private func makeOverlay(listener: @escaping RenderInteractionListener = { _ in }) ->
        (overlay: TrajectoryOverlayView, renderer: RecordingTrajectoryRenderer, binding: TrajectoryBinding, window: NSWindow) {
        let renderer = RecordingTrajectoryRenderer()
        let overlay = TrajectoryOverlayView(renderer: renderer)
        let window = makeWindow(content: overlay)
        overlay.configure(contentMode: .fit, mirrored: false, requested: true)
        overlay.setResolvedMediaSize(CGSize(width: 400, height: 200))
        overlay.layout()
        let binding = TrajectoryBinding(listener: listener, resolvedMediaSize: CGSize(width: 400, height: 200))
        binding.attach(to: overlay)
        binding.update(enabled: true)
        return (overlay, renderer, binding, window)
    }

    private func makeWindow(content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        content.layoutSubtreeIfNeeded()
        return window
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: y), to: nil),
            modifierFlags: [], timestamp: CACurrentMediaTime(), windowNumber: view.window!.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drain() async { try? await Task.sleep(for: .milliseconds(15)) }
}

@MainActor
private final class RecordingTrajectoryRenderer: TrajectoryEffectRendering {
    let view = NSView()
    var began: [TrajectoryPoint] = []
    var moved: [TrajectoryPoint] = []
    var ended: [TrajectoryID] = []
    var resetCount = 0
    func renderBegan(_ points: [TrajectoryPoint]) { began += points }
    func renderMoved(_ points: [TrajectoryPoint]) { moved += points }
    func renderEnded(_ ids: [TrajectoryID]) { ended += ids }
    func reset() { resetCount += 1 }
}

private actor TrajectoryFrameRecorder {
    var frames: [InteractionFrame] = []
    func append(_ frame: InteractionFrame) { frames.append(frame) }
    func last() -> InteractionFrame? { frames.last }
    func snapshot() -> [InteractionFrame] { frames }
    func count() -> Int { frames.count }
}

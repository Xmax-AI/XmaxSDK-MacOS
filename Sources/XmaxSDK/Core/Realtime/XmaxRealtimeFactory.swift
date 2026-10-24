//
//  XmaxRealtimeFactory.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The shared realtime dependencies used by the facade and lifecycle owner.
struct XmaxRealtimeComponents: Sendable {

    /// The operation admission and cleanup owner.
    let lifecycleManager: XmaxRealtimeLifecycleManager

    /// The server session, RTC connection, and output configuration owner.
    let connectionManager: XmaxRealtimeConnectionManager

    /// The generation signaling and result confirmation owner.
    let generationManager: XmaxRealtimeGenerationManager

    /// The shared runtime failure reporter.
    let errorManager: XmaxRealtimeErrorManager

    /// The local media and interaction controller.
    let mediaController: any MediaControlling

    /// The remote track and frame rendering controller.
    let renderController: any RenderControlling

    /// The RTC publishing, signaling, and quality controller.
    let streamController: any StreamControlling

    /// The model dimension and platform capability service.
    let mediaService: any MediaServicing

    /// The shared startup timing recorder.
    let timing: RealtimeTiming
}

/// Creates realtime dependencies and connects their frame, failure, and cleanup callbacks.
enum XmaxRealtimeFactory {

    /// Creates the default realtime components without starting capture or server requests.
    ///
    /// - Parameters:
    ///   - options: The model, interpolation, and adaptive quality configuration.
    ///   - apiService: The service used to create and maintain server sessions.
    ///
    /// - Returns: The configured components and their shared lifecycle manager.
    @MainActor
    static func make(
        options: RealtimeConfiguration,
        apiService: any ApiServicing
    ) -> XmaxRealtimeComponents {
        let errorManager = XmaxRealtimeErrorManager()
        let rtcManager = RtcManager()
        let mediaService = MediaService(model: options.model)
        let timing = RealtimeTiming()

        let renderController = RenderController(
            rtcManager: rtcManager,
            frameInterpolationEnabled: options.isFrameInterpolationEnabled,
            frameInterpolationSupportChecker: {
                mediaService.supportsFrameInterpolation(for: $0)
            },
            errorListener: {
                errorManager.forward(
                    $0,
                    target: .connection
                )
            }
        )

        let streamController = StreamController(
            rtcManager: rtcManager,
            errorListener: {
                errorManager.forward(
                    $0,
                    target: .connection
                )
            },
            remoteStreamListener: { stream in
                try renderController.setRemoteStream(stream)
            },
            timing: timing
        )

        let mediaController = MediaController(
            rtcManager: rtcManager,
            mediaService: mediaService,
            videoFrameListener: { frame in
                try streamController.pushLocalVideoFrame(frame)
            },
            requestingFrames: { streamController.hasGenerationTask },
            errorListener: {
                errorManager.forward(
                    $0,
                    target: .all
                )
            },
            interactionListener: { taskID, points in
                try await streamController.sendTracks(
                    taskID: taskID,
                    points: points
                )
            }
        )

        let connectionManager = XmaxRealtimeConnectionManager(
            sessionService: RealtimeSessionService(apiService: apiService),
            interactionController: mediaController,
            renderController: renderController,
            streamController: streamController,
            timing: timing,
            mediaService: mediaService,
            errorManager: errorManager
        )

        let generationManager = XmaxRealtimeGenerationManager(
            interactionController: mediaController,
            streamController: streamController,
            renderController: renderController,
            timing: timing
        )
        return assemble(
            connectionManager: connectionManager,
            generationManager: generationManager,
            errorManager: errorManager,
            mediaController: mediaController,
            renderController: renderController,
            streamController: streamController,
            mediaService: mediaService,
            timing: timing
        )
    }

    /// Connects supplied components to one lifecycle owner and shared cleanup policy.
    ///
    /// - Parameters:
    ///   - connectionManager: The server session and RTC connection manager.
    ///   - generationManager: The generation request and confirmation manager.
    ///   - errorManager: The shared runtime failure manager.
    ///   - mediaController: The local media and interaction controller.
    ///   - renderController: The remote rendering and output controller.
    ///   - streamController: The RTC publishing and signaling controller.
    ///   - mediaService: The model sizing and capability service.
    ///   - timing: The shared startup timing recorder.
    ///
    /// - Returns: The components with lifecycle admission, failure routing, and cleanup configured.
    static func assemble(
        connectionManager: XmaxRealtimeConnectionManager,
        generationManager: XmaxRealtimeGenerationManager,
        errorManager: XmaxRealtimeErrorManager,
        mediaController: any MediaControlling,
        renderController: any RenderControlling,
        streamController: any StreamControlling,
        mediaService: any MediaServicing,
        timing: RealtimeTiming
    ) -> XmaxRealtimeComponents {
        let lifecycleManager = XmaxRealtimeLifecycleManager(
            errorManager: errorManager,
            cleanup: { scope, taskID in
                await cleanup(
                    scope: scope,
                    taskID: taskID,
                    mediaController: mediaController,
                    connectionManager: connectionManager,
                    generationManager: generationManager
                )
            },
            stopLocalCapture: { await mediaController.stopLocalCapture() }
        )
        errorManager.setFailureHandler { [weak lifecycleManager] error, target, isCurrent in
            await lifecycleManager?.terminate(
                with: error,
                target: target,
                isCurrent: isCurrent
            )
        }
        return XmaxRealtimeComponents(
            lifecycleManager: lifecycleManager,
            connectionManager: connectionManager,
            generationManager: generationManager,
            errorManager: errorManager,
            mediaController: mediaController,
            renderController: renderController,
            streamController: streamController,
            mediaService: mediaService,
            timing: timing
        )
    }

    /// Releases generation, connection, or complete media resources in lifecycle order.
    ///
    /// - Parameters:
    ///   - scope: The resource scope to release.
    ///   - taskID: The task to stop; an empty string means no specific task.
    ///   - mediaController: The controller stopping capture or restoring local preview.
    ///   - connectionManager: The manager releasing RTC and the server session.
    ///   - generationManager: The manager stopping generation and clearing cached conditions.
    ///
    /// - Returns: The ended session identifier and whether local media remains usable.
    private static func cleanup(
        scope: XmaxRealtimeLifecycleManager.TerminationScope,
        taskID: String,
        mediaController: any MediaControlling,
        connectionManager: XmaxRealtimeConnectionManager,
        generationManager: XmaxRealtimeGenerationManager
    ) async -> XmaxRealtimeLifecycleManager.CleanupResult {

        if scope == .generation {
            do {
                try await generationManager.stop(taskID: taskID)
            } catch {
                XmaxLogger.realtime.error(
                    message: "停止实时生成失败 (Failed to Stop Realtime Generation)\n"
                        + "└─ \(XmaxLogger.localized("原因：", "Reason: "))\(ErrorMessageFormatter.format(error))"
                )
            }
            return XmaxRealtimeLifecycleManager.CleanupResult(
                sessionID: await connectionManager.currentSessionID,
                hasLocalMedia: await mediaController.currentTrack != nil
            )
        }

        if scope == .all {
            await mediaController.stopLocalCapture()
        }
        do {
            try await mediaController.stopMicrophoneCapture()
        } catch {
            XmaxLogger.realtime.error(
                message: """
                    停止麦克风采集失败 (Failed to Stop Microphone Capture)
                    └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                    """
            )
        }

        do {
            try await generationManager.reset(taskID: taskID)
        } catch {
            XmaxLogger.realtime.error(
                message: """
                    停止实时生成失败 (Failed to Stop Realtime Generation)
                    └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                    """
            )
        }

        let activeSessionID = await connectionManager.currentSessionID
        var sessionID = activeSessionID.isEmpty ? nil : activeSessionID
        do {
            sessionID = try await connectionManager.disconnect() ?? sessionID
        } catch {
            XmaxLogger.realtime.error(
                message: """
                    断开实时连接失败 (Failed to Disconnect Realtime)
                    └─ \(XmaxLogger.localized("原因：", "Reason: "))\((error as NSError).localizedDescription)
                    """
            )
        }

        if scope == .all {
            await mediaController.stopLocalStream()
        }
        return XmaxRealtimeLifecycleManager.CleanupResult(
            sessionID: sessionID,
            hasLocalMedia: await mediaController.currentTrack != nil
        )
    }
}

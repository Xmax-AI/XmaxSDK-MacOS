//
//  XmaxRealtimeGenerationManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Checks that the current generation operation remains valid.
///
/// - Throws: An error if the operation is invalid or cancelled.
typealias RealtimeGenerationValidity = @Sendable () throws -> Void

/// Coordinates generation signals, remote result confirmation, condition updates, and trajectory interactions.
actor XmaxRealtimeGenerationManager {

    /// The controller that manages trajectory interactions during generation.
    private let interactionController: any InteractionControlling

    /// The controller that publishes local media and sends generation signaling.
    private let streamController: any StreamControlling

    /// Observes processed result frames without owning the connection or remote track.
    private let renderController: any RenderControlling

    /// The recorder for result confirmation and first-frame readiness.
    private let timing: RealtimeTiming

    /// The closure that generates identifiers for new tasks.
    private let taskIDGenerator: @Sendable () -> String

    /// The prompt and reference image from the most recent successful request.
    private var currentContext: RealtimeContext?

    /// The face restoration setting from the most recent successful request.
    private var currentFaceRestoration = false

    /// Reuses face restoration from the last successful request when generation restarts automatically.
    var cachedFaceRestoration: Bool { currentFaceRestoration }

    /// Creates a realtime generation manager.
    init(
        interactionController: any InteractionControlling,
        streamController: any StreamControlling,
        renderController: any RenderControlling,
        timing: RealtimeTiming = RealtimeTiming(),
        taskIDGenerator: @escaping @Sendable () -> String =
            XmaxRealtimeGenerationManager.createTaskID
    ) {
        self.interactionController = interactionController
        self.streamController = streamController
        self.renderController = renderController
        self.taskIDGenerator = taskIDGenerator
        self.timing = timing
    }

    /// Requires context for initial generation and permits cached context for later requests.
    ///
    /// - Parameter context: The generation context; `nil` checks the cached context.
    ///
    /// - Throws: An error if neither a new context nor a reusable cached context is available.
    func validateContext(
        _ context: RealtimeContext?
    ) throws {
        guard context != nil || currentContext != nil else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "A realtime context is required for the first generation"
            )
        }
    }

    /// Sends a generation request and confirms the result stream, first displayable frame, and audio activation.
    ///
    /// - Parameters:
    ///   - videoFormat: The local media format used to configure interaction coordinates.
    ///   - targetSize: The return video dimensions; `nil` uses server defaults.
    ///   - context: The generation context; `nil` reuses the last successful request's context.
    ///   - faceRestoration: Whether to enable face restoration.
    ///   - generationVideoFormat: The server generation format; `nil` uses the local media format.
    ///   - paddingContain: Whether to pad the image to preserve all content.
    ///   - ensureCurrent: The callback checking this operation's validity.
    ///
    /// - Returns: The generation task identifier whose result stream and first frame are ready.
    ///
    /// - Throws: An error on missing context, signal or result confirmation failure, or invalid operation.
    func start(
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext?,
        faceRestoration: Bool = false,
        generationVideoFormat: RealtimeVideoFormat? = nil,
        paddingContain: Bool = false,
        ensureCurrent: @escaping RealtimeGenerationValidity
    ) async throws -> String {
        guard let resolvedContext = context ?? currentContext else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "A realtime context is required for the first generation"
            )
        }

        let taskID = taskIDGenerator()
        await renderController.setInteractionEnabled(false)
        let confirmation = try await streamController.beginGeneration(
            taskID: taskID,
            videoFormat: generationVideoFormat ?? videoFormat,
            targetSize: targetSize,
            context: resolvedContext,
            faceRestoration: faceRestoration,
            paddingContain: paddingContain
        )
        do {
            try await withTaskCancellationHandler {
                try await confirmation.value
            } onCancel: {
                confirmation.cancel()
            }
            try ensureCurrent()

            await interactionController.startInteraction(
                taskID: taskID,
                videoFormat: videoFormat
            )
            try ensureCurrent()
            await renderController.setInteractionEnabled(true)
            try ensureCurrent()
            try await renderController.waitUntilRemoteFrameReady()
            try ensureCurrent()
            timing.finishFirstFrame(taskID: taskID)
            try streamController.activateRemoteAudio()
            try ensureCurrent()
            currentContext = resolvedContext
            currentFaceRestoration = faceRestoration
            return taskID
        } catch {
            try? await stop(taskID: taskID)
            throw XmaxError.from(error)
        }
    }

    /// Updates generation conditions and interaction for the current task without awaiting new result confirmation.
    ///
    /// - Parameters:
    ///   - taskID: The generation task identifier to update.
    ///   - videoFormat: The local media format used to configure interaction coordinates.
    ///   - targetSize: The return video dimensions; `nil` omits return dimensions.
    ///   - context: The generation context; `nil` reuses the last successful request's context.
    ///   - faceRestoration: Whether to enable face restoration.
    ///   - generationVideoFormat: The server generation format; `nil` uses the local media format.
    ///   - paddingContain: Whether to pad the image to preserve all content.
    ///   - ensureCurrent: The callback checking this operation's validity.
    ///
    /// - Throws: An error on missing context, condition update failure, or invalid operation.
    func update(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext?,
        faceRestoration: Bool = false,
        generationVideoFormat: RealtimeVideoFormat? = nil,
        paddingContain: Bool = false,
        ensureCurrent: RealtimeGenerationValidity = {}
    ) async throws {
        guard let resolvedContext = context ?? currentContext else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "A realtime context is required for the first generation"
            )
        }

        try await streamController.updateGeneration(
            taskID: taskID,
            videoFormat: generationVideoFormat ?? videoFormat,
            targetSize: targetSize,
            context: resolvedContext,
            faceRestoration: faceRestoration,
            paddingContain: paddingContain
        )
        try ensureCurrent()
        await renderController.setInteractionEnabled(false)
        await interactionController.startInteraction(
            taskID: taskID,
            videoFormat: videoFormat
        )
        try ensureCurrent()
        await renderController.setInteractionEnabled(true)
        try ensureCurrent()
        currentContext = resolvedContext
        currentFaceRestoration = faceRestoration
    }

    /// Stops interaction and sends the generation stop signal.
    ///
    /// - Parameter taskID: The generation task identifier to stop.
    ///
    /// - Throws: An error if sending the generation stop signal fails.
    func stop(
        taskID: String
    ) async throws {
        await renderController.setInteractionEnabled(false)
        await interactionController.stopInteraction()
        try await streamController.stopGeneration(taskID: taskID)
    }

    /// Clears cached generation conditions and stops generation and interaction.
    ///
    /// - Parameter taskID: The task identifier to stop; an empty string if there is no task.
    ///
    /// - Throws: An error if sending the generation stop signal fails.
    func reset(
        taskID: String = ""
    ) async throws {
        currentContext = nil
        currentFaceRestoration = false
        try await stop(taskID: taskID)
    }

    /// Creates a random task identifier with the macOS platform marker.
    ///
    /// - Returns: A task identifier formatted as `task-<22 URL-safe random characters>?os=macos`.
    nonisolated static func createTaskID() -> String {
        var uuid = UUID().uuid
        let data = withUnsafeBytes(of: &uuid) { Data($0) }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(
                of: "+",
                with: "-"
            )
            .replacingOccurrences(
                of: "/",
                with: "_"
            )
            .replacingOccurrences(
                of: "=",
                with: ""
            )
        return "task-\(encoded)?os=\(RuntimeInfo.current.platform)"
    }
}

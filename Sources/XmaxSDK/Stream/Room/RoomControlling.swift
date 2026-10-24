//
//  RoomControlling.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics

/// Defines RTC room lifecycle and business signaling capabilities.
protocol RoomControlling: Actor {

    /// Joins the realtime room and checks connection validity across asynchronous boundaries.
    ///
    /// - Parameters:
    ///   - connection: The server-assigned RTC connection information.
    ///   - ensureActive: The callback checking current connection validity.
    ///
    /// - Throws: An error on invalid room state, RTC join failure, timeout, or cancellation.
    func join(
        connection: RealtimeSessionConnection,
        ensureActive: @escaping @Sendable () throws -> Void
    ) async throws

    /// Stops room heartbeats and leaves the current RTC room.
    func leave() async

    /// Enqueues a generation start signal for the room.
    ///
    /// - Parameters:
    ///   - taskID: The current generation task identifier.
    ///   - videoFormat: The server generation video format.
    ///   - targetSize: The returned pixel dimensions; `nil` preserves generation dimensions.
    ///   - context: The current generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve source aspect ratio and pad the generation canvas.
    ///
    /// - Throws: An error if the room is unready or signal encoding or enqueueing fails.
    func startGeneration(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize?,
        context: RealtimeContext,
        faceRestoration: Bool,
        paddingContain: Bool
    ) throws

    /// Enqueues a generation condition update signal for the room.
    ///
    /// - Parameters:
    ///   - taskID: The current generation task identifier.
    ///   - videoFormat: The server generation video format.
    ///   - targetSize: The returned pixel dimensions; `nil` preserves generation dimensions.
    ///   - context: The current generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve source aspect ratio and pad the generation canvas.
    ///
    /// - Throws: An error on unready room, cancellation, signal encoding failure, or enqueueing failure.
    func changeGenerationCondition(
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize?,
        context: RealtimeContext,
        faceRestoration: Bool,
        paddingContain: Bool
    ) throws

    /// Adjusts return dimensions for the current generation task.
    ///
    /// - Parameters:
    ///   - taskID: The current generation task identifier.
    ///   - targetSize: The returned integer-pixel dimensions.
    ///   - ensureActive: Checks current configuration operation validity before sending.
    ///
    /// - Throws: An error on cancellation, unready room, or signal send failure.
    func changeTargetSize(
        taskID: String,
        targetSize: CGSize,
        ensureActive: @Sendable () throws -> Void
    ) async throws

    /// Enqueues a stop signal; ignores an unjoined room or empty task.
    ///
    /// - Parameter taskID: The generation task identifier to stop.
    ///
    /// - Throws: An error if stop signal encoding or enqueueing fails.
    func stopGeneration(
        taskID: String
    ) throws

    /// Submits an interaction trajectory for the current generation task.
    ///
    /// - Parameters:
    ///   - taskID: The destination task identifier; empty values are not sent.
    ///   - points: Media-normalized points in `[0, 1]`; empty arrays are not sent.
    ///
    /// - Throws: An error on unready room, trajectory encoding failure, or signal enqueueing failure.
    func sendTracks(
        taskID: String,
        points: [RealtimePoint]
    ) throws
}

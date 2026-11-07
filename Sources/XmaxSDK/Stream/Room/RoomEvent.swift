//
//  RoomEvent.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Creates structured event messages exchanged between the SDK and RTC room.
enum RoomEvent {

    /// Encodes a generation start signal with runtime environment information.
    ///
    /// - Parameters:
    ///   - userID: The local RTC user account.
    ///   - taskID: The current generation task identifier.
    ///   - videoFormat: The server generation video format.
    ///   - targetSize: The returned pixel dimensions; `nil` preserves generation dimensions.
    ///   - context: The current generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve source aspect ratio and pad the generation canvas.
    ///   - xid: The logical command identifier retained across retransmissions.
    ///
    /// - Returns: The sendable JSON start signal.
    ///
    /// - Throws: An error on invalid generation parameters, bitrate calculation failure, or JSON encoding failure.
    static func start(
        userID: String,
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false,
        xid: String? = nil
    ) throws -> String {
        try encode(
            .start,
            userID: userID,
            taskID: taskID,
            xid: xid,
            params: GenerationParameters(
                videoFormat: videoFormat,
                targetSize: targetSize,
                context: context,
                faceRestoration: faceRestoration,
                paddingContain: paddingContain,
                mirror: false
            )
        )
    }

    /// Encodes generation condition updates with runtime environment information.
    ///
    /// - Parameters:
    ///   - userID: The local RTC user account.
    ///   - taskID: The current generation task identifier.
    ///   - videoFormat: The server generation video format.
    ///   - targetSize: The returned pixel dimensions; `nil` preserves generation dimensions.
    ///   - context: The current generation conditions.
    ///   - faceRestoration: Whether to restore the original face.
    ///   - paddingContain: Whether to preserve source aspect ratio and pad the generation canvas.
    ///   - xid: The logical command identifier retained across retransmissions.
    ///
    /// - Returns: The sendable JSON condition update signal.
    ///
    /// - Throws: An error on invalid generation parameters or JSON encoding failure.
    static func changeCondition(
        userID: String,
        taskID: String,
        videoFormat: RealtimeVideoFormat,
        targetSize: CGSize? = nil,
        context: RealtimeContext,
        faceRestoration: Bool = false,
        paddingContain: Bool = false,
        xid: String? = nil
    ) throws -> String {
        try encode(
            .changeCondition,
            userID: userID,
            taskID: taskID,
            xid: xid,
            params: GenerationParameters(
                videoFormat: videoFormat,
                targetSize: targetSize,
                context: context,
                faceRestoration: faceRestoration,
                paddingContain: paddingContain
            )
        )
    }

    /// Encodes return dimension and downstream bitrate updates.
    ///
    /// - Parameters:
    ///   - userID: The local RTC user account.
    ///   - taskID: The generation task identifier to update.
    ///   - targetSize: The returned integer-pixel dimensions.
    ///   - xid: The logical command identifier retained across retransmissions.
    ///
    /// - Returns: The sendable JSON return dimension update signal.
    ///
    /// - Throws: An error on invalid target dimensions, bitrate calculation failure, or JSON encoding failure.
    static func changeTargetSize(
        userID: String,
        taskID: String,
        targetSize: CGSize,
        xid: String? = nil
    ) throws -> String {
        try encode(
            .changeTargetSize,
            userID: userID,
            taskID: taskID,
            xid: xid,
            params: TargetSizeParameters(size: targetSize)
        )
    }

    /// Encodes a generation stop signal.
    ///
    /// - Parameters:
    ///   - userID: The local RTC user account.
    ///   - taskID: The generation task identifier to stop.
    ///
    /// - Returns: The sendable JSON stop signal.
    ///
    /// - Throws: An error if JSON encoding fails.
    static func stop(
        userID: String,
        taskID: String
    ) throws -> String {
        try encode(
            .stop,
            userID: userID,
            taskID: taskID
        )
    }

    /// Encodes a generation task's media-normalized trajectory.
    ///
    /// - Parameters:
    ///   - userID: The local RTC user account.
    ///   - taskID: The generation task receiving the trajectory.
    ///   - points: Points in sample order, normalized to `[0, 1]` relative to processed media dimensions.
    ///
    /// - Returns: The sendable JSON trajectory signal.
    ///
    /// - Throws: An error on invalid coordinates or JSON encoding failure.
    static func tracks(
        userID: String,
        taskID: String,
        points: [RealtimePoint]
    ) throws -> String {
        try encode(
            .tracks,
            userID: userID,
            taskID: taskID,
            tracks: points.map { [$0.x, $0.y] }
        )
    }

    /// Encodes a room heartbeat signal.
    ///
    /// - Parameter userID: The local RTC user account.
    ///
    /// - Returns: The sendable JSON heartbeat signal.
    ///
    /// - Throws: An error if JSON encoding fails.
    static func heartbeat(
        userID: String
    ) throws -> String {
        try encode(
            .heartbeat,
            userID: userID
        )
    }
}

private extension RoomEvent {

    /// Validates return dimensions and calculates downstream bitrate budget.
    ///
    /// - Parameter size: The return video integer-pixel dimensions.
    ///
    /// - Returns: A 500 kbps minimum and a maximum clamped to 500...10000 kbps.
    ///
    /// - Throws: An error on invalid dimensions or bitrate calculation failure.
    static func downlinkBitrates(
        _ size: CGSize
    ) throws -> (minimum: Int, maximum: Int) {
        guard let width = Int(exactly: size.width),
            let height = Int(exactly: size.height),
            width >= 2, height >= 2
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Invalid return video dimensions"
            )
        }
        let fps = QualityVideoFormat.downlinkFrameRate
        try RealtimeVideoFormat.validateDimensions(
            width: width,
            height: height,
            fps: fps
        )
        let maximum = try EncodingBitratePolicy.estimateMaximum(
            width: width,
            height: height,
            fps: fps
        )
        return (500, min(10000, max(500, maximum)))
    }

    /// Encodes a room message with stable key ordering.
    static func encode(
        _ event: Event,
        userID: String,
        taskID: String? = nil,
        xid: String? = nil,
        params: (any Encodable)? = nil,
        tracks: [[Double]]? = nil
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try String(
            decoding: encoder.encode(
                Message(
                    event: event,
                    userID: userID,
                    taskID: taskID,
                    xid: xid,
                    params: params,
                    tracks: tracks
                )
            ),
            as: UTF8.self
        )
    }

    /// Event names used by the room protocol.
    enum Event: String, Encodable {

        /// Starts a generation task.
        case start

        /// Updates generation conditions.
        case changeCondition = "change_condition"

        /// Updates return dimensions.
        case changeTargetSize = "change_target_size"

        /// Stops a generation task.
        case stop

        /// Sends interaction points.
        case tracks

        /// Keeps the room active.
        case heartbeat
    }

    /// The shared room message and its event-specific fields.
    struct Message: Encodable {

        /// The event name.
        let event: Event

        /// The local RTC user account.
        let userID: String

        /// The generation task identifier, when the event belongs to a task.
        let taskID: String?

        /// The logical command identifier retained across retransmissions.
        let xid: String?

        /// The generation or return dimension parameters, when present.
        let params: (any Encodable)?

        /// The normalized points in sample order, when present.
        let tracks: [[Double]]?

        /// Field names defined by the room protocol.
        enum CodingKeys: String, CodingKey {
            case event
            case userID = "user_id"
            case taskID = "uid"
            case sessionTaskID = "session_uid"
            case xid
            case params
            case tracks
            case runtime
        }

        /// Writes the runtime metadata and fields applicable to this event.
        func encode(
            to encoder: Encoder
        ) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(event, forKey: .event)
            try container.encode(userID, forKey: .userID)
            try container.encodeIfPresent(taskID, forKey: .taskID)
            try container.encodeIfPresent(taskID, forKey: .sessionTaskID)
            try container.encodeIfPresent(xid, forKey: .xid)
            if let params {
                try container.encode(params, forKey: .params)
            }
            try container.encodeIfPresent(tracks, forKey: .tracks)
            try container.encode(RuntimeInfo.current, forKey: .runtime)
        }
    }

    /// Encodes generation dimensions, reference conditions, and output options.
    struct GenerationParameters: Encodable {

        /// The signaling model placeholder; the session determines the actual model.
        let model = "default"

        /// The generation canvas dimensions, in pixels.
        let size: [Int]

        /// The returned output dimensions, in pixels.
        let targetSize: [Int]?

        /// The generation prompt.
        let prompt: String

        /// The server-accessible reference image URL.
        let referencePath: String?

        /// Whether to mirror the input.
        let mirror: Bool?

        /// Whether face restoration is enabled.
        let faceRestoration: Bool

        /// The input-to-canvas padding policy.
        let padding: String?

        /// The server encoder minimum bitrate, in kbps.
        let minimumBitrate: Int?

        /// The server encoder maximum bitrate, in kbps.
        let maximumBitrate: Int?

        /// Creates generation parameters, optionally including downstream bitrate configuration.
        ///
        /// - Parameters:
        ///   - videoFormat: The server generation video format.
        ///   - targetSize: The return dimensions; `nil` preserves generation dimensions.
        ///   - context: The generation conditions, including reference images and prompt.
        ///   - faceRestoration: Whether to restore the original face.
        ///   - paddingContain: Whether to fit content within the canvas using padding.
        ///   - mirror: The optional mirror setting; a non-nil value also adds downstream bitrate fields.
        ///
        /// - Throws: An error on invalid dimensions or bitrate when downstream bitrate calculation is required.
        init(
            videoFormat: RealtimeVideoFormat,
            targetSize: CGSize?,
            context: RealtimeContext,
            faceRestoration: Bool,
            paddingContain: Bool = false,
            mirror: Bool? = nil
        ) throws {
            size = [videoFormat.width, videoFormat.height]
            self.targetSize = targetSize.map { [Int($0.width), Int($0.height)] }
            prompt = context.prompt
            referencePath = context.referencePath
            self.mirror = mirror
            self.faceRestoration = faceRestoration
            padding = paddingContain ? "contain" : nil
            if mirror != nil {
                let budget = try RoomEvent.downlinkBitrates(targetSize ?? videoFormat.size)
                minimumBitrate = budget.minimum
                maximumBitrate = budget.maximum
            } else {
                minimumBitrate = nil
                maximumBitrate = nil
            }
        }

        /// Maps field names defined by the server signaling protocol.
        enum CodingKeys: String, CodingKey {

            /// The generation model field.
            case model

            /// The generation canvas field.
            case size

            /// The returned dimensions field.
            case targetSize = "target_size"

            /// The generation prompt field.
            case prompt

            /// The reference image field.
            case referencePath = "ref_image_path"

            /// The input mirroring field.
            case mirror

            /// The face restoration field.
            case faceRestoration = "face_replace"

            /// The canvas padding field.
            case padding

            /// The minimum bitrate field.
            case minimumBitrate = "min_bitrate"

            /// The maximum bitrate field.
            case maximumBitrate = "max_bitrate"
        }
    }

    /// Encodes return dimensions and the associated downstream bitrate budget.
    struct TargetSizeParameters: Encodable {

        /// The returned output dimensions, in pixels.
        let targetSize: [Int]

        /// The server encoder minimum bitrate, in kbps.
        let minimumBitrate: Int

        /// The server encoder maximum bitrate, in kbps.
        let maximumBitrate: Int

        /// Validates and creates return dimension and bitrate parameters.
        ///
        /// - Parameter size: The target return dimensions in integer pixels.
        ///
        /// - Throws: An error on dimension validation or downstream bitrate calculation failure.
        init(
            size: CGSize
        ) throws {
            let budget = try RoomEvent.downlinkBitrates(size)
            targetSize = [Int(size.width), Int(size.height)]
            minimumBitrate = budget.minimum
            maximumBitrate = budget.maximum
        }

        /// Maps field names defined by the server signaling protocol.
        enum CodingKeys: String, CodingKey {

            /// The returned dimensions field.
            case targetSize = "target_size"

            /// The minimum bitrate field.
            case minimumBitrate = "min_bitrate"

            /// The maximum bitrate field.
            case maximumBitrate = "max_bitrate"
        }
    }
}

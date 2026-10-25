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
        paddingContain: Bool = false
    ) throws -> String {
        try encode(
            StartPayload(
                params: GenerationParameters(
                    videoFormat: videoFormat,
                    targetSize: targetSize,
                    context: context,
                    faceRestoration: faceRestoration,
                    paddingContain: paddingContain,
                    mirror: false
                ),
                userID: userID,
                taskID: taskID
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
        paddingContain: Bool = false
    ) throws -> String {
        try encode(
            ChangeConditionPayload(
                params: GenerationParameters(
                    videoFormat: videoFormat,
                    targetSize: targetSize,
                    context: context,
                    faceRestoration: faceRestoration,
                    paddingContain: paddingContain
                ),
                userID: userID,
                taskID: taskID
            )
        )
    }

    /// Encodes return dimension and downstream bitrate updates.
    ///
    /// - Parameters:
    ///   - userID: The local RTC user account.
    ///   - taskID: The generation task identifier to update.
    ///   - targetSize: The returned integer-pixel dimensions.
    ///
    /// - Returns: The sendable JSON return dimension update signal.
    ///
    /// - Throws: An error on invalid target dimensions, bitrate calculation failure, or JSON encoding failure.
    static func changeTargetSize(
        userID: String,
        taskID: String,
        targetSize: CGSize
    ) throws -> String {
        try encode(
            ChangeTargetSizePayload(
                params: TargetSizeParameters(size: targetSize),
                userID: userID,
                taskID: taskID
            )
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
            StopPayload(
                userID: userID,
                taskID: taskID
            )
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
            TracksPayload(
                tracks: points.map { [$0.x, $0.y] },
                userID: userID,
                taskID: taskID
            )
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
        try encode(HeartbeatPayload(userID: userID))
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
        guard size.width.isFinite, size.height.isFinite,
            size.width >= 2, size.height >= 2,
            size.width < CGFloat(Int.max), size.height < CGFloat(Int.max),
            size.width.rounded(.down) == size.width,
            size.height.rounded(.down) == size.height
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Invalid return video dimensions"
            )
        }
        let budget = try EncodingBitratePolicy.resolve(
            RealtimeVideoFormat(
                width: Int(size.width),
                height: Int(size.height),
                fps: 24
            )
        )
        return (500, min(10000, max(500, budget.maximum)))
    }

    /// Adds runtime environment and session task fields, then encodes the signal.
    ///
    /// - Parameter payload: The encodable business event payload.
    ///
    /// - Returns: The UTF-8 JSON text with stable key ordering.
    ///
    /// - Throws: An error on payload encoding, JSON conversion, or text conversion failure.
    static func encode(
        _ payload: some Encodable
    ) throws -> String {
        let payloadData = try JSONEncoder().encode(
            Envelope(
                payload: payload,
                runtime: .current
            )
        )
        guard var object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw XmaxError(
                code: .internalError,
                message: "Failed to encode RTC room event"
            )
        }
        if let taskID = object["uid"] {
            object["session_uid"] = taskID
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard
            let message = String(
                data: data,
                encoding: .utf8
            )
        else {
            throw XmaxError(
                code: .internalError,
                message: "Failed to encode RTC room event"
            )
        }
        return message
    }

    /// Adds runtime environment information to business signals.
    struct Envelope<Payload: Encodable>: Encodable {

        /// The business event payload.
        let payload: Payload

        /// The client runtime information sent with signaling.
        let runtime: RuntimeInfo

        /// Writes the business payload and runtime environment into one encoding container.
        ///
        /// - Parameter encoder: The encoder emitting the signal.
        ///
        /// - Throws: An error if payload or runtime environment encoding fails.
        func encode(
            to encoder: Encoder
        ) throws {
            try payload.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                runtime,
                forKey: .runtime
            )
        }

        /// Maps field names defined by the server signaling protocol.
        enum CodingKeys: String, CodingKey {

            /// The client runtime field.
            case runtime
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

    /// A room signal starting generation.
    struct StartPayload: Encodable {

        /// The start event name.
        let event = "start"

        /// The generation dimensions, conditions, and display settings.
        let params: GenerationParameters

        /// The business user starting generation.
        let userID: String

        /// The generation task identifier.
        let taskID: String

        /// Maps field names defined by the server signaling protocol.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The event parameters field.
            case params

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
        }
    }

    /// A room signal updating generation conditions.
    struct ChangeConditionPayload: Encodable {

        /// The condition update event name.
        let event = "change_condition"

        /// The updated generation and display conditions.
        let params: GenerationParameters

        /// The task's business user identifier.
        let userID: String

        /// The generation task identifier.
        let taskID: String

        /// Maps field names defined by the server signaling protocol.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The event parameters field.
            case params

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
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

    /// A room signal dynamically adjusting return dimensions.
    struct ChangeTargetSizePayload: Encodable {

        /// The target-size event name.
        let event = "change_target_size"

        /// The new output dimensions and bitrate bounds.
        let params: TargetSizeParameters

        /// The task's business user identifier.
        let userID: String

        /// The generation task identifier.
        let taskID: String

        /// Maps field names defined by the server signaling protocol.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The event parameters field.
            case params

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
        }
    }

    /// A room signal stopping generation.
    struct StopPayload: Encodable {

        /// The stop event name.
        let event = "stop"

        /// The task's business user identifier.
        let userID: String

        /// The generation task identifier.
        let taskID: String

        /// Maps field names defined by the server signaling protocol.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
        }
    }

    /// A room signal carrying a generation task's media-normalized trajectory.
    struct TracksPayload: Encodable {

        /// The trajectory event name.
        let event = "tracks"

        /// The normalized points relative to complete resolved media dimensions, each as `[x, y]`.
        let tracks: [[Double]]

        /// The business user sending the trajectory.
        let userID: String

        /// The trajectory's generation task identifier.
        let taskID: String

        /// Maps field names defined by the server signaling protocol.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The normalized trajectory field.
            case tracks

            /// The business user field.
            case userID = "user_id"

            /// The generation task field.
            case taskID = "uid"
        }
    }

    /// A heartbeat signal keeping the room active.
    struct HeartbeatPayload: Encodable {

        /// The room heartbeat event name.
        let event = "heartbeat"

        /// The business user sending the heartbeat.
        let userID: String

        /// Maps field names defined by the server signaling protocol.
        enum CodingKeys: String, CodingKey {

            /// The event name field.
            case event

            /// The business user field.
            case userID = "user_id"
        }
    }
}

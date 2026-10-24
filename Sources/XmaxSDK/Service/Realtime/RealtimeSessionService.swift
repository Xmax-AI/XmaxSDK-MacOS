//
//  RealtimeSessionService.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Manages realtime session creation, heartbeat maintenance, and closure.
final class RealtimeSessionService: RealtimeSessionServicing, @unchecked Sendable {

    /// The session API service.
    private let apiService: any ApiServicing

    /// The heartbeat interval provider.
    private let heartbeatSleeper: RealtimeHeartbeatSleeper

    /// The lock protecting heartbeat startup and cancellation.
    private let heartbeatLock = NSLock()

    /// The revision rejecting stale heartbeat results.
    private let heartbeatVersion = RealtimeHeartbeatVersion()

    /// The current session heartbeat task.
    private var heartbeatTask: Task<Void, Never>?

    /// Creates a realtime session service with a periodic heartbeat wait strategy.
    init(
        apiService: any ApiServicing,
        heartbeatSleeper: RealtimeHeartbeatSleeper = .live
    ) {
        self.apiService = apiService
        self.heartbeatSleeper = heartbeatSleeper
    }

    /// Invalidates the current heartbeat and cancels unfinished periodic work.
    deinit {
        heartbeatVersion.advance()
        heartbeatTask?.cancel()
    }

    /// Creates a model session and parses RTC join information.
    ///
    /// - Parameter model: The realtime generation model for this session.
    ///
    /// - Returns: The server-created session and RTC connection information.
    ///
    /// - Throws: An error on request failure, missing response fields, or cancellation.
    func createSession(
        model: RealtimeModel
    ) async throws -> RealtimeSession {
        let payload = try await apiService.post(
            "/session",
            body: CreateSessionRequest(model: model.rawValue),
            as: SessionPayload.self
        )
        do {
            return try Self.makeSession(
                from: payload,
                requiresConnection: true
            )
        } catch {
            if let sessionID = Self.nonEmpty(payload.sessionUID) {
                do {
                    try await closeSession(sessionID: sessionID)
                } catch {
                    XmaxLogger.realtime.error(
                        message: "关闭无效会话失败 (Failed to Close Invalid Session)\n└─ \(error.localizedDescription)"
                    )
                }
            }
            throw error
        }
    }

    /// Starts periodic heartbeats for the specified session, replacing the previous heartbeat task.
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier to keep alive.
    ///   - onFailure: The callback receiving session identity and error on heartbeat failure.
    func startHeartbeat(
        sessionID: String,
        onFailure: @escaping RealtimeSessionHeartbeatFailureHandler
    ) {
        heartbeatLock.withLock {
            let version = heartbeatVersion.advance()
            heartbeatTask?.cancel()

            let context = HeartbeatContext(
                apiService: apiService,
                sleeper: heartbeatSleeper,
                versionState: heartbeatVersion,
                version: version,
                sessionID: sessionID,
                onFailure: onFailure
            )
            heartbeatTask = Task {
                await Self.runHeartbeat(context)
            }
        }
    }

    /// Stops the heartbeat and invalidates pending failure notifications.
    func stopHeartbeat() {
        heartbeatLock.withLock {
            heartbeatVersion.advance()
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    /// Closes the specified server session.
    ///
    /// - Parameter sessionID: The session identifier to close.
    ///
    /// - Throws: An error on close request failure or cancellation.
    func closeSession(
        sessionID: String
    ) async throws {
        do {
            _ = try await apiService.delete(
                "/session/\(sessionID)",
                as: EmptyResponse.self
            )
        } catch {
            throw XmaxError.from(error)
        }
    }
}

private extension RealtimeSessionService {

    /// The model information submitted during session creation.
    struct CreateSessionRequest: Encodable, Sendable {

        /// The model identifier for session creation.
        let model: String
    }

    /// Receives successful responses without business fields.
    struct EmptyResponse: Decodable, Sendable {}

    /// Stores the service, session, and validity information for one heartbeat loop.
    struct HeartbeatContext: Sendable {

        /// The session heartbeat API service.
        let apiService: any ApiServicing

        /// The wait for the next heartbeat interval.
        let sleeper: RealtimeHeartbeatSleeper

        /// The current heartbeat validity check.
        let versionState: RealtimeHeartbeatVersion

        /// The heartbeat loop revision.
        let version: UInt64

        /// The session kept alive by this heartbeat.
        let sessionID: String

        /// The session heartbeat failure handler.
        let onFailure: RealtimeSessionHeartbeatFailureHandler
    }

    /// Receives server session fields for business-layer validation.
    struct SessionPayload: Decodable, Sendable {

        /// The response session identifier.
        let sessionUID: String?

        /// The response user identifier.
        let userUID: String?

        /// The server-reported session state.
        let status: String?

        /// The RTC connection payload.
        let modelExtra: ModelExtra?

        /// The server session closure reason.
        let closeReason: String?

        /// Defines decoding mappings between server fields and local properties.
        enum CodingKeys: String, CodingKey {

            /// The session identifier field.
            case sessionUID = "sessionUid"

            /// The server user identifier field.
            case userUID = "userUid"

            /// The session state field.
            case status

            /// The model connection payload field.
            case modelExtra

            /// The session closure reason field.
            case closeReason
        }

        /// Decodes a session response, setting unparseable optional fields to nil.
        ///
        /// - Parameter decoder: The decoder supplying session response data.
        ///
        /// - Throws: A decoding error if a keyed container cannot be created.
        init(
            from decoder: any Decoder
        ) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionUID = try? container.decode(
                String.self,
                forKey: .sessionUID
            )
            userUID = try? container.decode(
                String.self,
                forKey: .userUID
            )
            status = try? container.decode(
                String.self,
                forKey: .status
            )
            modelExtra = try? container.decode(
                ModelExtra.self,
                forKey: .modelExtra
            )
            closeReason = try? container.decode(
                String.self,
                forKey: .closeReason
            )
        }
    }

    /// Receives extra RTC parameters as an object or JSON string.
    enum ModelExtra: Decodable, Sendable {

        /// An RTC connection object.
        case object(ConnectionPayload)

        /// RTC connection information encoded as a JSON string.
        case json(String)

        /// An unrecognized connection payload.
        case invalid

        /// Decodes extra RTC connection information as an object or JSON string.
        ///
        /// - Parameter decoder: The decoder supplying extra information.
        ///
        /// - Throws: A decoding error if a single-value container cannot be created.
        init(
            from decoder: any Decoder
        ) throws {
            let container = try decoder.singleValueContainer()
            if let json = try? container.decode(String.self) {
                self = .json(json)
            } else if let payload = try? ConnectionPayload(from: decoder) {
                self = .object(payload)
            } else {
                self = .invalid
            }
        }
    }

    /// Receives RTC join fields and application identity.
    struct ConnectionPayload: Decodable, Sendable {

        /// The response RTC room identifier.
        let roomID: String?

        /// The RTC room token.
        let token: String?

        /// The local RTC user identifier.
        let userID: String?

        /// The remote user providing generated media.
        let botName: String?

        /// The RTC application identifier.
        let appID: String?

        /// Defines decoding mappings between server fields and local properties.
        enum CodingKeys: String, CodingKey {

            /// The RTC room identifier field.
            case roomID = "room_id"

            /// The RTC token field.
            case token = "room_token"

            /// The local RTC user field.
            case userID = "rtc_user_id"

            /// The remote generation user field.
            case botName = "rtc_bot_id"

            /// The RTC application field.
            case appID = "rtc_app_id"
        }

        /// Decodes RTC connection parameters, setting unparseable optional fields to nil.
        ///
        /// - Parameter decoder: The decoder supplying RTC connection fields.
        ///
        /// - Throws: A decoding error if a keyed container cannot be created.
        init(
            from decoder: any Decoder
        ) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            roomID = try? container.decode(
                String.self,
                forKey: .roomID
            )
            token = try? container.decode(
                String.self,
                forKey: .token
            )
            userID = try? container.decode(
                String.self,
                forKey: .userID
            )
            botName = try? container.decode(
                String.self,
                forKey: .botName
            )
            appID = try? container.decode(
                String.self,
                forKey: .appID
            )
        }
    }

    /// Sends periodic heartbeats for valid sessions, notifying and ending the loop after the first valid failure.
    ///
    /// - Parameter context: The current heartbeat session, wait strategy, and validity information.
    static func runHeartbeat(
        _ context: HeartbeatContext
    ) async {
        while context.versionState.isCurrent(context.version) {
            do {
                try await context.sleeper.sleep()
                try Task.checkCancellation()
                guard context.versionState.isCurrent(context.version) else {
                    return
                }

                let session = try await heartbeatSession(
                    sessionID: context.sessionID,
                    apiService: context.apiService
                )
                guard context.versionState.isCurrent(context.version) else {
                    return
                }
                try ensureSessionActive(session)
            } catch {
                guard context.versionState.invalidate(context.version) else {
                    return
                }
                await context.onFailure(
                    context.sessionID,
                    XmaxError.from(error)
                )
                return
            }
        }
    }

    /// Sends one session heartbeat and parses the latest state.
    ///
    /// - Parameters:
    ///   - sessionID: The session identifier to keep alive.
    ///   - apiService: The API service sending heartbeat requests.
    ///
    /// - Returns: The latest session state from the server.
    ///
    /// - Throws: An error on request failure, invalid response, or cancellation.
    static func heartbeatSession(
        sessionID: String,
        apiService: any ApiServicing
    ) async throws -> RealtimeSession {
        let payload = try await apiService.put(
            "/session/\(sessionID)/heartbeat",
            as: SessionPayload.self
        )
        return try makeSession(
            from: payload,
            requiresConnection: false
        )
    }

    /// Checks whether the server explicitly ended the session.
    ///
    /// - Parameter session: The session whose state should be checked.
    ///
    /// - Throws: A session error if its state is nonempty and not `ACTIVE`.
    static func ensureSessionActive(
        _ session: RealtimeSession
    ) throws {
        guard let status = session.status, status != "ACTIVE" else {
            return
        }
        throw XmaxError(
            code: .sessionError,
            message: session.closeReason
                ?? "Session is no longer active: \(status)"
        )
    }

    /// Validates required fields and converts the response to a realtime session.
    ///
    /// - Parameters:
    ///   - payload: The original server session fields.
    ///   - requiresConnection: Whether complete, valid RTC connection information is required.
    ///
    /// - Returns: The normalized and validated session.
    ///
    /// - Throws: A session error if identity is missing or required RTC connection information is invalid.
    static func makeSession(
        from payload: SessionPayload,
        requiresConnection: Bool
    ) throws -> RealtimeSession {
        guard let sessionID = nonEmpty(payload.sessionUID) else {
            throw XmaxError(
                code: .sessionError,
                message: "Invalid session response"
            )
        }

        let userID = nonEmpty(payload.userUID)
        let connection = makeConnection(from: payload.modelExtra)
        if requiresConnection, connection == nil {
            throw XmaxError(
                code: .sessionError,
                message: "Session does not contain complete RTC join information"
            )
        }

        return RealtimeSession(
            id: sessionID,
            userID: userID,
            status: nonEmpty(payload.status),
            connection: connection,
            closeReason: nonEmpty(payload.closeReason)
        )
    }

    /// Parses extra RTC fields and validates application identity.
    ///
    /// - Parameter modelExtra: The extra RTC fields as an object or JSON string.
    ///
    /// - Returns: Complete connection parameters matching the current RTC app, or `nil` for invalid fields.
    static func makeConnection(
        from modelExtra: ModelExtra?
    ) -> RealtimeSessionConnection? {
        let payload: ConnectionPayload
        switch modelExtra {
        case .object(let value):
            payload = value
        case .json(let value):
            guard let data = value.data(using: .utf8),
                let value = try? JSONDecoder().decode(
                    ConnectionPayload.self,
                    from: data
                )
            else {
                return nil
            }
            payload = value
        case .invalid, nil:
            return nil
        }

        guard let roomID = nonEmpty(payload.roomID),
            let token = nonEmpty(payload.token),
            let userID = nonEmpty(payload.userID),
            let botName = nonEmpty(payload.botName),
            nonEmpty(payload.appID) == RtcEngineManager.defaultAppID
        else {
            return nil
        }
        return RealtimeSessionConnection(
            roomID: roomID,
            userID: userID,
            token: token,
            botName: botName
        )
    }

    /// Trims strings and rejects empty content.
    ///
    /// - Parameter value: The optional string to normalize.
    ///
    /// - Returns: The nonempty normalized string, or `nil` without valid content.
    static func nonEmpty(
        _ value: String?
    ) -> String? {
        let normalized = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized?.isEmpty == false ? normalized : nil
    }
}

/// Wraps the asynchronous wait strategy before each heartbeat.
struct RealtimeHeartbeatSleeper: Sendable {

    /// The cancellable heartbeat wait.
    let sleep: @Sendable () async throws -> Void

    /// A heartbeat wait using a 10-second interval.
    static let live = RealtimeHeartbeatSleeper {
        try await Task.sleep(nanoseconds: 10_000_000_000)
    }
}

/// Uses a version counter to invalidate late results from stopped heartbeats.
private final class RealtimeHeartbeatVersion: @unchecked Sendable {

    /// The lock protecting heartbeat revision updates.
    private let lock = NSLock()

    /// The current heartbeat revision.
    private var value: UInt64 = 0

    /// Advances the heartbeat version, invalidating earlier results.
    ///
    /// - Returns: The updated version.
    @discardableResult
    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    /// Checks whether a heartbeat version belongs to the current lifecycle.
    ///
    /// - Parameter version: The heartbeat version to check.
    ///
    /// - Returns: `true` if it matches the current version.
    func isCurrent(
        _ version: UInt64
    ) -> Bool {
        lock.withLock { value == version }
    }

    /// Advances the version only if still valid, invalidating that heartbeat.
    ///
    /// - Parameter version: The heartbeat version to invalidate.
    ///
    /// - Returns: `true` if the current version was invalidated; `false` for stale versions.
    func invalidate(
        _ version: UInt64
    ) -> Bool {
        lock.withLock {
            guard value == version else {
                return false
            }
            value &+= 1
            return true
        }
    }
}

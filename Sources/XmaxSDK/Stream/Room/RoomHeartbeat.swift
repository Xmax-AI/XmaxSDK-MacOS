//
//  RoomHeartbeat.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Sends periodic RTC room heartbeats while isolating stopped cycles.
final class RoomHeartbeat: @unchecked Sendable {

    /// The room signaling RTC manager.
    private let rtcManager: any RtcManaging

    /// The room heartbeat interval provider.
    private let sleeper: HeartbeatSleeper

    /// The revision separating heartbeat cycles.
    private let cycle = HeartbeatVersion()

    /// The lock protecting heartbeat task replacement.
    private let taskLock = NSLock()

    /// The current room heartbeat task.
    private var heartbeatTask: Task<Void, Never>?

    /// Creates a room heartbeat component with the specified wait strategy.
    init(
        rtcManager: any RtcManaging,
        sleeper: HeartbeatSleeper = .live
    ) {
        self.rtcManager = rtcManager
        self.sleeper = sleeper
    }

    /// Invalidates the heartbeat cycle and cancels its background task.
    deinit {
        cycle.advance()
        heartbeatTask?.cancel()
    }

    /// Replaces the previous cycle and starts room heartbeats for the specified user.
    ///
    /// - Parameter userID: The local user account sending heartbeats.
    func start(
        userID: String
    ) {
        taskLock.withLock {
            let version = cycle.advance()
            heartbeatTask?.cancel()
            let context = Context(
                rtcManager: rtcManager,
                sleeper: sleeper,
                cycle: cycle,
                version: version,
                userID: userID
            )
            heartbeatTask = Task {
                await Self.run(context)
            }
        }
    }

    /// Invalidates the current cycle and cancels its task.
    func stop() {
        taskLock.withLock {
            cycle.advance()
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }
}

private extension RoomHeartbeat {

    /// Stores send dependencies and validity for one heartbeat cycle.
    struct Context: Sendable {

        /// The RTC room heartbeat sender.
        let rtcManager: any RtcManaging

        /// The wait for the next room heartbeat.
        let sleeper: HeartbeatSleeper

        /// The room heartbeat validity check.
        let cycle: HeartbeatVersion

        /// The heartbeat loop revision.
        let version: UInt64

        /// The business user sending room heartbeats.
        let userID: String
    }

    /// Sends heartbeats using the wait strategy, ignoring late results from stopped cycles.
    ///
    /// - Parameter context: The current cycle's dependencies and identity.
    static func run(
        _ context: Context
    ) async {
        while context.cycle.isCurrent(context.version) {
            do {
                try await context.sleeper.sleep()
                try Task.checkCancellation()
                guard context.cycle.isCurrent(context.version) else {
                    return
                }
                try context.rtcManager.sendRoomMessage(
                    RoomEvent.heartbeat(userID: context.userID)
                )
            } catch is CancellationError {
                return
            } catch {
                guard context.cycle.isCurrent(context.version) else {
                    return
                }
                XmaxLogger.room.error(
                    message:
                        "发送 RTC 房间心跳失败 (Failed to Send RTC Room Heartbeat)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))"
                        + (error as NSError).localizedDescription
                )
            }
        }
    }
}

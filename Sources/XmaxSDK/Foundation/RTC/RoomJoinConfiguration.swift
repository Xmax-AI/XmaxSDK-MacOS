//
//  RoomJoinConfiguration.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// RTC room join parameters.
struct RoomJoinConfiguration: Equatable, Sendable {

    /// The RTC room identifier to join.
    let roomID: String

    /// The local RTC user identifier.
    let userID: String

    /// The room authentication token.
    let token: String
}

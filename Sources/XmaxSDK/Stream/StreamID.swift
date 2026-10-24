//
//  StreamID.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Internal SDK identifiers for local and remote media streams.
enum StreamID: String, Sendable {

    /// The local input stream identifier.
    case local = "stream-local"

    /// The remote result stream identifier.
    case remote = "stream-remote"
}

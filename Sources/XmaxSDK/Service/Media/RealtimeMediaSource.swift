//
//  RealtimeMediaSource.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Local media sources supported by a realtime generation model.
public enum RealtimeMediaSource: String, CaseIterable, Sendable {

    /// Camera input.
    case camera

    /// Video frames supplied by your app.
    case external

    /// Video file input.
    case video

    /// Image input.
    case image
}

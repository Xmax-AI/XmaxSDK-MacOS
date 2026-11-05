//
//  RealtimeMicrophoneLevel.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Receives physical microphone input strength on the main actor.
///
/// A finite value in `0...1` represents relative input strength; zero is a measured silence.
/// `nil` means no valid microphone reading is available. Values are intended for a visual
/// indicator, rather than calibrated decibels or microphone gain.
public typealias RealtimeMicrophoneLevelListener =
    @MainActor @Sendable (
        Float?
    ) -> Void

//
//  RealtimePoint.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// A normalized interaction point relative to processed media, from the top-left origin to `(1, 1)` at bottom right.
struct RealtimePoint: Equatable, Sendable {

    /// The normalized horizontal position within the full media width, in `[0, 1]`.
    let x: Double

    /// The normalized vertical position within the full media height, in `[0, 1]`.
    let y: Double
}

//
//  VideoContentMode.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The video content display mode within its rendering container.
public enum VideoContentMode: String, CaseIterable, Sendable {

    /// Fits all content proportionally, allowing empty space.
    case fit

    /// Fills the container proportionally, allowing cropping.
    case fill
}

//
//  VideoPixelFormat.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Pixel formats supported by neutral video frames.
enum VideoPixelFormat: String, CaseIterable, Sendable {

    /// Biplanar 4:2:0 with Y and interleaved UV planes.
    case nv12

    /// Blue, green, red, and alpha pixels.
    case bgra
}

//
//  CameraRotation.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Clockwise camera rotation applied before horizontal mirroring.
public enum CameraRotation: Int, CaseIterable, Sendable {

    /// Preserves the upright camera orientation.
    case degrees0 = 0

    /// Rotates clockwise by a quarter turn.
    case degrees90 = 90

    /// Rotates by a half turn.
    case degrees180 = 180

    /// Rotates clockwise by three quarter turns.
    case degrees270 = 270

    /// Whether rotation exchanges the input width and height.
    var swapsDimensions: Bool {
        self == .degrees90 || self == .degrees270
    }
}

//
//  MediaServicing+Generation.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics

public extension MediaServicing {

    /// Resolves a generation canvas using this service's model rules by default.
    func resolveGenerationSize(
        _ size: CGSize
    ) throws -> CGSize {
        try MediaService(model: model).resolveGenerationSize(size)
    }
}

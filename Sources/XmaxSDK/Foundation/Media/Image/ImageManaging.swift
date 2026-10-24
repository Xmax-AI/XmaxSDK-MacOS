//
//  ImageManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines internal platform image decoding capabilities.
protocol ImageManaging: Sendable {

    /// Decodes image data, applies orientation, and returns reusable pixel data.
    ///
    /// - Parameter data: Encoded image data in JPEG, PNG, or another supported format.
    ///
    /// - Returns: The decoded image with source orientation applied.
    ///
    /// - Throws: An error on empty data, unsupported formats, or image decoding failure.
    func decode(
        _ data: Data
    ) throws -> any DecodedImage
}

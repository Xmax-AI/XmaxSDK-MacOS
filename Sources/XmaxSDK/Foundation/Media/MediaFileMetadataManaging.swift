//
//  MediaFileMetadataManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines local media file metadata reading capabilities.
protocol MediaFileMetadataManaging: Sendable {

    /// Reads original video dimensions, display rotation, duration, and audio track information.
    ///
    /// - Parameter fileURL: The readable local video file URL.
    ///
    /// - Returns: The metadata used to prepare a local video stream.
    ///
    /// - Throws: An error if the file is unreadable, lacks video tracks, or has invalid metadata.
    func readMetadata(
        fileURL: URL
    ) async throws -> MediaFileMetadata
}

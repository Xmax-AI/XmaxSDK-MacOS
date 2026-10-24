//
//  XmaxDownloadedFile.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// A file downloaded to local storage.
public struct XmaxDownloadedFile: Equatable, Sendable {

    /// The downloaded local file URL.
    public let fileURL: URL

    /// The downloaded file size in bytes.
    public let byteCount: Int64

    /// Creates a download result.
    init(
        fileURL: URL,
        byteCount: Int64
    ) {
        self.fileURL = fileURL
        self.byteCount = byteCount
    }
}

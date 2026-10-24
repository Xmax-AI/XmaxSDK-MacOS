//
//  DownloadedFile.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// The neutral result of a completed remote file download.
struct DownloadedFile: Equatable, Sendable {

    /// The downloaded local file URL.
    let fileURL: URL

    /// The downloaded byte count.
    let byteCount: Int64
}

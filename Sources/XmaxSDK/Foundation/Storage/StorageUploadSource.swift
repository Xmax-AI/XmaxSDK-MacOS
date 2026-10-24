//
//  StorageUploadSource.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Binary data or a local file supported by object storage uploads.
enum StorageUploadSource: Equatable, Sendable {

    /// Uploads in-memory data.
    case data(Data)

    /// Uploads a local file.
    case file(URL)
}

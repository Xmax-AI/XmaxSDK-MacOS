//
//  XmaxStorageProgressHandler.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Receives file upload or download progress.
///
/// - Parameter progress: Progress containing completed and total byte counts.
public typealias XmaxStorageProgressHandler = @Sendable (Progress) -> Void

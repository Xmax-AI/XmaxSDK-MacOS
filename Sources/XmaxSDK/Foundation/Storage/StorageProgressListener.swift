//
//  StorageProgressListener.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The storage progress callback receiving completed and total byte counts.
typealias StorageProgressListener =
    @Sendable (
        _ completedBytes: Int64,
        _ totalBytes: Int64
    ) -> Void

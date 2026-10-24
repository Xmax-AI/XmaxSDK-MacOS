//
//  StorageManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines basic file upload and download capabilities.
protocol StorageManaging: Sendable {

    /// Uploads data or a local file with temporary credentials.
    ///
    /// - Parameters:
    ///   - source: The binary data or local file to upload.
    ///   - objectKey: The destination object path within the bucket.
    ///   - contentType: The upload content MIME type.
    ///   - configuration: The storage endpoint, bucket, and temporary credentials.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The upload result with access URL, object path, and ETag when available.
    ///
    /// - Throws: An error on invalid input or credentials, upload failure, or cancellation.
    func upload(
        source: StorageUploadSource,
        objectKey: String,
        contentType: String,
        configuration: StorageConfiguration,
        progress: StorageProgressListener?
    ) async throws -> StoredFile

    /// Downloads a remote file to the specified local destination.
    ///
    /// - Parameters:
    ///   - remoteURL: The remote file URL to download.
    ///   - destinationURL: The local destination file URL.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The completed local file URL and byte count.
    ///
    /// - Throws: An error on invalid URLs, download or file write failure, or cancellation.
    func download(
        remoteURL: URL,
        destinationURL: URL,
        progress: StorageProgressListener?
    ) async throws -> DownloadedFile
}

extension StorageManaging {

    /// Uploads data or a local file without progress reporting.
    ///
    /// - Parameters:
    ///   - source: The binary data or local file to upload.
    ///   - objectKey: The destination object path within the bucket.
    ///   - contentType: The upload content MIME type.
    ///   - configuration: The storage endpoint, bucket, and temporary credentials.
    ///
    /// - Returns: The upload result with access URL, object path, and ETag when available.
    ///
    /// - Throws: An error on invalid input or credentials, upload failure, or cancellation.
    func upload(
        source: StorageUploadSource,
        objectKey: String,
        contentType: String,
        configuration: StorageConfiguration
    ) async throws -> StoredFile {
        try await upload(
            source: source,
            objectKey: objectKey,
            contentType: contentType,
            configuration: configuration,
            progress: nil
        )
    }

    /// Downloads a remote file without progress reporting.
    ///
    /// - Parameters:
    ///   - remoteURL: The remote file URL to download.
    ///   - destinationURL: The local destination file URL.
    ///
    /// - Returns: The completed local file URL and byte count.
    ///
    /// - Throws: An error on invalid URLs, download or file write failure, or cancellation.
    func download(
        remoteURL: URL,
        destinationURL: URL
    ) async throws -> DownloadedFile {
        try await download(
            remoteURL: remoteURL,
            destinationURL: destinationURL,
            progress: nil
        )
    }
}

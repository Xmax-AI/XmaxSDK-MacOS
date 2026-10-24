//
//  StorageServicing.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines image and video upload and download, and image safety checking.
protocol StorageServicing: Sendable {

    /// Uploads image data.
    ///
    /// - Parameters:
    ///   - data: The encoded image file data.
    ///   - fileName: The filename including extension, used to construct object paths.
    ///   - contentType: The file MIME type.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The upload result with access URL, object path, and ETag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadImage(
        data: Data,
        fileName: String,
        contentType: String,
        progress: StorageProgressListener?
    ) async throws -> StoredFile

    /// Uploads a local image file.
    ///
    /// - Parameters:
    ///   - fileURL: The readable local image file URL.
    ///   - contentType: The file MIME type; inferred from the filename when `nil`.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The upload result with access URL, object path, and ETag when available.
    ///
    /// - Throws: An error on invalid files, credential retrieval failure, or upload failure.
    func uploadImageFile(
        fileURL: URL,
        contentType: String?,
        progress: StorageProgressListener?
    ) async throws -> StoredFile

    /// Uploads image data and passes content safety checks.
    ///
    /// - Parameters:
    ///   - data: The encoded image file data.
    ///   - fileName: The filename including extension, used to construct object paths.
    ///   - contentType: The file MIME type.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The upload result with access URL, object path, and ETag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval or upload failure, or safety check failure.
    func uploadImageWithSafetyCheck(
        data: Data,
        fileName: String,
        contentType: String,
        progress: StorageProgressListener?
    ) async throws -> StoredFile

    /// Uploads a local image file and passes content safety checks.
    ///
    /// - Parameters:
    ///   - fileURL: The readable local image file URL.
    ///   - contentType: The file MIME type; inferred from the filename when `nil`.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The upload result with access URL, object path, and ETag when available.
    ///
    /// - Throws: An error on invalid files, credential retrieval or upload failure, or safety check failure.
    func uploadImageFileWithSafetyCheck(
        fileURL: URL,
        contentType: String?,
        progress: StorageProgressListener?
    ) async throws -> StoredFile

    /// Uploads video data.
    ///
    /// - Parameters:
    ///   - data: The encoded video file data.
    ///   - fileName: The filename including extension, used to construct object paths.
    ///   - contentType: The file MIME type.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The upload result with access URL, object path, and ETag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadVideo(
        data: Data,
        fileName: String,
        contentType: String,
        progress: StorageProgressListener?
    ) async throws -> StoredFile

    /// Uploads a local video file.
    ///
    /// - Parameters:
    ///   - fileURL: The readable local video file URL.
    ///   - contentType: The file MIME type; inferred from the filename when `nil`.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The upload result with access URL, object path, and ETag when available.
    ///
    /// - Throws: An error on invalid files, credential retrieval failure, or upload failure.
    func uploadVideoFile(
        fileURL: URL,
        contentType: String?,
        progress: StorageProgressListener?
    ) async throws -> StoredFile

    /// Downloads a remote image to a local file.
    ///
    /// - Parameters:
    ///   - remoteURL: The remote file URL to download.
    ///   - destinationURL: The local destination file URL.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The completed local file URL and byte count.
    ///
    /// - Throws: An error on invalid URLs, download or file write failure, or cancellation.
    func downloadImage(
        remoteURL: URL,
        destinationURL: URL,
        progress: StorageProgressListener?
    ) async throws -> DownloadedFile

    /// Downloads a remote video to a local file.
    ///
    /// - Parameters:
    ///   - remoteURL: The remote file URL to download.
    ///   - destinationURL: The local destination file URL.
    ///   - progress: The transferred and total byte count callback; `nil` disables progress reporting.
    ///
    /// - Returns: The completed local file URL and byte count.
    ///
    /// - Throws: An error on invalid URLs, download or file write failure, or cancellation.
    func downloadVideo(
        remoteURL: URL,
        destinationURL: URL,
        progress: StorageProgressListener?
    ) async throws -> DownloadedFile
}

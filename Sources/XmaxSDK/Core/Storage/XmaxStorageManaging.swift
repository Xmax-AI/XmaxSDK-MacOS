//
//  XmaxStorageManaging.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Defines public file upload and download capabilities.
public protocol XmaxStorageManaging: Sendable {

    /// Uploads image data.
    ///
    /// - Parameters:
    ///   - data: The encoded image file data.
    ///   - fileName: The filename including extension, used to construct the storage object name.
    ///   - contentType: The file MIME type, such as image/jpeg.
    ///   - progress: The transfer progress callback; nil disables progress reporting.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadImage(
        _ data: Data,
        fileName: String,
        contentType: String,
        progress: XmaxStorageProgressHandler?
    ) async throws -> XmaxUploadedFile

    /// Uploads a local image file.
    ///
    /// - Parameters:
    ///   - fileURL: The readable local image file URL.
    ///   - contentType: The file MIME type; inferred from the filename when nil.
    ///   - progress: The transfer progress callback; nil disables progress reporting.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadImage(
        at fileURL: URL,
        contentType: String?,
        progress: XmaxStorageProgressHandler?
    ) async throws -> XmaxUploadedFile

    /// Uploads image data and returns after content safety checks pass.
    ///
    /// - Parameters:
    ///   - data: The encoded image file data.
    ///   - fileName: The filename including extension, used to construct the storage object name.
    ///   - contentType: The file MIME type, such as image/jpeg.
    ///   - progress: The transfer progress callback; nil disables progress reporting.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential or upload failure, or failed content safety checks.
    func uploadImageWithSafetyCheck(
        _ data: Data,
        fileName: String,
        contentType: String,
        progress: XmaxStorageProgressHandler?
    ) async throws -> XmaxUploadedFile

    /// Uploads a local image file and returns after content safety checks pass.
    ///
    /// - Parameters:
    ///   - fileURL: The readable local image file URL.
    ///   - contentType: The file MIME type; inferred from the filename when nil.
    ///   - progress: The transfer progress callback; nil disables progress reporting.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential or upload failure, or failed content safety checks.
    func uploadImageWithSafetyCheck(
        at fileURL: URL,
        contentType: String?,
        progress: XmaxStorageProgressHandler?
    ) async throws -> XmaxUploadedFile

    /// Uploads video data.
    ///
    /// - Parameters:
    ///   - data: The encoded video file data.
    ///   - fileName: The filename including extension, used to construct the storage object name.
    ///   - contentType: The file MIME type, such as video/mp4.
    ///   - progress: The transfer progress callback; nil disables progress reporting.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadVideo(
        _ data: Data,
        fileName: String,
        contentType: String,
        progress: XmaxStorageProgressHandler?
    ) async throws -> XmaxUploadedFile

    /// Uploads a local video file.
    ///
    /// - Parameters:
    ///   - fileURL: The readable local video file URL.
    ///   - contentType: The file MIME type; inferred from the filename when nil.
    ///   - progress: The transfer progress callback; nil disables progress reporting.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadVideo(
        at fileURL: URL,
        contentType: String?,
        progress: XmaxStorageProgressHandler?
    ) async throws -> XmaxUploadedFile

    /// Downloads an image to the specified local file.
    ///
    /// - Parameters:
    ///   - remoteURL: The remote image URL to download.
    ///   - destinationURL: The destination local file URL.
    ///   - progress: The transfer progress callback; nil disables progress reporting.
    ///
    /// - Returns: The local file URL and downloaded byte count.
    ///
    /// - Throws: An error on invalid URLs, file write failure, or download failure.
    func downloadImage(
        from remoteURL: URL,
        to destinationURL: URL,
        progress: XmaxStorageProgressHandler?
    ) async throws -> XmaxDownloadedFile

    /// Downloads a video to the specified local file.
    ///
    /// - Parameters:
    ///   - remoteURL: The remote video URL to download.
    ///   - destinationURL: The destination local file URL.
    ///   - progress: The transfer progress callback; nil disables progress reporting.
    ///
    /// - Returns: The local file URL and downloaded byte count.
    ///
    /// - Throws: An error on invalid URLs, file write failure, or download failure.
    func downloadVideo(
        from remoteURL: URL,
        to destinationURL: URL,
        progress: XmaxStorageProgressHandler?
    ) async throws -> XmaxDownloadedFile
}

public extension XmaxStorageManaging {

    /// Uploads image data without progress reporting.
    ///
    /// - Parameters:
    ///   - data: The encoded image file data.
    ///   - fileName: The filename including extension, used to construct the storage object name.
    ///   - contentType: The file MIME type, such as image/jpeg.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadImage(
        _ data: Data,
        fileName: String,
        contentType: String
    ) async throws -> XmaxUploadedFile {
        try await uploadImage(
            data,
            fileName: fileName,
            contentType: contentType,
            progress: nil
        )
    }

    /// Uploads a local image file without progress reporting.
    ///
    /// - Parameters:
    ///   - fileURL: The readable local image file URL.
    ///   - contentType: The file MIME type; inferred from the filename when nil.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadImage(
        at fileURL: URL,
        contentType: String? = nil
    ) async throws -> XmaxUploadedFile {
        try await uploadImage(
            at: fileURL,
            contentType: contentType,
            progress: nil
        )
    }

    /// Uploads image data and returns after content safety checks pass, without progress reporting.
    ///
    /// - Parameters:
    ///   - data: The encoded image file data.
    ///   - fileName: The filename including extension, used to construct the storage object name.
    ///   - contentType: The file MIME type, such as image/jpeg.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential or upload failure, or failed content safety checks.
    func uploadImageWithSafetyCheck(
        _ data: Data,
        fileName: String,
        contentType: String
    ) async throws -> XmaxUploadedFile {
        try await uploadImageWithSafetyCheck(
            data,
            fileName: fileName,
            contentType: contentType,
            progress: nil
        )
    }

    /// Uploads a local image file and returns after content safety checks pass, without progress reporting.
    ///
    /// - Parameters:
    ///   - fileURL: The readable local image file URL.
    ///   - contentType: The file MIME type; inferred from the filename when nil.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential or upload failure, or failed content safety checks.
    func uploadImageWithSafetyCheck(
        at fileURL: URL,
        contentType: String? = nil
    ) async throws -> XmaxUploadedFile {
        try await uploadImageWithSafetyCheck(
            at: fileURL,
            contentType: contentType,
            progress: nil
        )
    }

    /// Uploads video data without progress reporting.
    ///
    /// - Parameters:
    ///   - data: The encoded video file data.
    ///   - fileName: The filename including extension, used to construct the storage object name.
    ///   - contentType: The file MIME type, such as video/mp4.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadVideo(
        _ data: Data,
        fileName: String,
        contentType: String
    ) async throws -> XmaxUploadedFile {
        try await uploadVideo(
            data,
            fileName: fileName,
            contentType: contentType,
            progress: nil
        )
    }

    /// Uploads a local video file without progress reporting.
    ///
    /// - Parameters:
    ///   - fileURL: The readable local video file URL.
    ///   - contentType: The file MIME type; inferred from the filename when nil.
    ///
    /// - Returns: The uploaded file URL, object identifier, and entity tag when available.
    ///
    /// - Throws: An error on invalid input, credential retrieval failure, or upload failure.
    func uploadVideo(
        at fileURL: URL,
        contentType: String? = nil
    ) async throws -> XmaxUploadedFile {
        try await uploadVideo(
            at: fileURL,
            contentType: contentType,
            progress: nil
        )
    }

    /// Downloads an image to the specified local file without progress reporting.
    ///
    /// - Parameters:
    ///   - remoteURL: The remote image URL to download.
    ///   - destinationURL: The destination local file URL.
    ///
    /// - Returns: The local file URL and downloaded byte count.
    ///
    /// - Throws: An error on invalid URLs, file write failure, or download failure.
    func downloadImage(
        from remoteURL: URL,
        to destinationURL: URL
    ) async throws -> XmaxDownloadedFile {
        try await downloadImage(
            from: remoteURL,
            to: destinationURL,
            progress: nil
        )
    }

    /// Downloads a video to the specified local file without progress reporting.
    ///
    /// - Parameters:
    ///   - remoteURL: The remote video URL to download.
    ///   - destinationURL: The destination local file URL.
    ///
    /// - Returns: The local file URL and downloaded byte count.
    ///
    /// - Throws: An error on invalid URLs, file write failure, or download failure.
    func downloadVideo(
        from remoteURL: URL,
        to destinationURL: URL
    ) async throws -> XmaxDownloadedFile {
        try await downloadVideo(
            from: remoteURL,
            to: destinationURL,
            progress: nil
        )
    }
}

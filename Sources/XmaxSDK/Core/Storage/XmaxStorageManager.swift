//
//  XmaxStorageManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Public file storage entry point adapting service capabilities to public APIs.
final class XmaxStorageManager: XmaxStorageManaging, Sendable {

    /// The service that uploads, downloads, and checks media.
    private let storageService: any StorageServicing

    /// Creates a file manager with the specified storage service.
    init(
        storageService: any StorageServicing
    ) {
        self.storageService = storageService
    }

    /// Creates a file manager using the default object storage implementation.
    ///
    /// - Parameter apiService: The API service providing temporary storage credentials and content safety checks.
    convenience init(
        apiService: any ApiServicing
    ) {
        self.init(
            storageService: StorageService(
                apiService: apiService,
                storageManager: StorageManager()
            )
        )
    }

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
    ) async throws -> XmaxUploadedFile {
        try await uploadedFile {
            try await storageService.uploadImage(
                data: data,
                fileName: fileName,
                contentType: contentType,
                progress: progressListener(progress)
            )
        }
    }

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
    ) async throws -> XmaxUploadedFile {
        try await uploadedFile {
            try await storageService.uploadImageFile(
                fileURL: fileURL,
                contentType: contentType,
                progress: progressListener(progress)
            )
        }
    }

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
    ) async throws -> XmaxUploadedFile {
        try await uploadedFile {
            try await storageService.uploadImageWithSafetyCheck(
                data: data,
                fileName: fileName,
                contentType: contentType,
                progress: progressListener(progress)
            )
        }
    }

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
    ) async throws -> XmaxUploadedFile {
        try await uploadedFile {
            try await storageService.uploadImageFileWithSafetyCheck(
                fileURL: fileURL,
                contentType: contentType,
                progress: progressListener(progress)
            )
        }
    }

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
    ) async throws -> XmaxUploadedFile {
        try await uploadedFile {
            try await storageService.uploadVideo(
                data: data,
                fileName: fileName,
                contentType: contentType,
                progress: progressListener(progress)
            )
        }
    }

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
    ) async throws -> XmaxUploadedFile {
        try await uploadedFile {
            try await storageService.uploadVideoFile(
                fileURL: fileURL,
                contentType: contentType,
                progress: progressListener(progress)
            )
        }
    }

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
    ) async throws -> XmaxDownloadedFile {
        try await downloadedFile {
            try await storageService.downloadImage(
                remoteURL: remoteURL,
                destinationURL: destinationURL,
                progress: progressListener(progress)
            )
        }
    }

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
    ) async throws -> XmaxDownloadedFile {
        try await downloadedFile {
            try await storageService.downloadVideo(
                remoteURL: remoteURL,
                destinationURL: destinationURL,
                progress: progressListener(progress)
            )
        }
    }
}

private extension XmaxStorageManager {

    /// Converts byte progress into the public file progress callback.
    ///
    /// - Parameter handler: The callback receiving Progress; nil disables reporting.
    ///
    /// - Returns: The byte progress listener for storage services, or nil if no callback was provided.
    func progressListener(
        _ handler: XmaxStorageProgressHandler?
    ) -> StorageProgressListener? {
        guard let handler else {
            return nil
        }
        return { completedBytes, totalBytes in
            let progress = Progress(totalUnitCount: totalBytes)
            progress.completedUnitCount = completedBytes
            handler(progress)
        }
    }

    /// Uploads a file and converts the result to the public upload type.
    ///
    /// - Parameter operation: The asynchronous operation returning the service upload result.
    ///
    /// - Returns: The remote file information exposed to callers.
    ///
    /// - Throws: The converted XmaxError on upload failure.
    func uploadedFile(
        _ operation: () async throws -> StoredFile
    ) async throws -> XmaxUploadedFile {
        do {
            let file = try await operation()
            return XmaxUploadedFile(
                url: file.url,
                objectKey: file.objectKey,
                etag: file.etag
            )
        } catch {
            throw XmaxError.from(error)
        }
    }

    /// Downloads a file and converts the result to the public download type.
    ///
    /// - Parameter operation: The asynchronous operation returning the service download result.
    ///
    /// - Returns: The local file information exposed to callers.
    ///
    /// - Throws: The converted XmaxError on download failure.
    func downloadedFile(
        _ operation: () async throws -> DownloadedFile
    ) async throws -> XmaxDownloadedFile {
        do {
            let file = try await operation()
            return XmaxDownloadedFile(
                fileURL: file.fileURL,
                byteCount: file.byteCount
            )
        } catch {
            throw XmaxError.from(error)
        }
    }
}

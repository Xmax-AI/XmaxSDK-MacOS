//
//  XmaxStorageManagerTests.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import XCTest
@testable import XmaxSDK

final class XmaxStorageManagerTests: XCTestCase {
    func testUploadImageDelegatesDataAndConvertsProgressAndResult() async throws {
        let service = XmaxStorageServiceStub()
        let manager = XmaxStorageManager(storageService: service)
        let progressRecorder = XmaxStorageProgressRecorder()
        let data = Data("image".utf8)

        let result = try await manager.uploadImage(
            data,
            fileName: "image.png",
            contentType: "image/png",
            progress: progressRecorder.handler
        )

        XCTAssertEqual(
            service.calls,
            [
                .uploadImage(
                    data: data,
                    fileName: "image.png",
                    contentType: "image/png",
                    hasProgress: true
                )
            ]
        )
        XCTAssertEqual(
            progressRecorder.values,
            [XmaxStorageProgressValue(completed: 25, total: 100)]
        )
        XCTAssertEqual(
            result,
            XmaxUploadedFile(
                url: URL(string: "https://example.com/file")!,
                objectKey: "uploads/file",
                etag: "etag"
            )
        )
    }

    func testUploadImageFileWithSafetyCheckUsesNativeURL() async throws {
        let service = XmaxStorageServiceStub()
        let manager = XmaxStorageManager(storageService: service)
        let fileURL = URL(fileURLWithPath: "/tmp/image.heic")

        _ = try await manager.uploadImageWithSafetyCheck(
            at: fileURL,
            contentType: nil
        )

        XCTAssertEqual(
            service.calls,
            [
                .uploadImageFileWithSafetyCheck(
                    fileURL: fileURL,
                    contentType: nil,
                    hasProgress: false
                )
            ]
        )
    }

    func testUploadVideoFileDelegatesOptionalContentType() async throws {
        let service = XmaxStorageServiceStub()
        let manager = XmaxStorageManager(storageService: service)
        let fileURL = URL(fileURLWithPath: "/tmp/video.mov")

        _ = try await manager.uploadVideo(
            at: fileURL,
            contentType: "video/quicktime"
        )

        XCTAssertEqual(
            service.calls,
            [
                .uploadVideoFile(
                    fileURL: fileURL,
                    contentType: "video/quicktime",
                    hasProgress: false
                )
            ]
        )
    }

    func testImageAndVideoDownloadsDelegateURLsAndConvertResults() async throws {
        let service = XmaxStorageServiceStub()
        let manager = XmaxStorageManager(storageService: service)
        let imageURL = URL(string: "https://example.com/image.png")!
        let videoURL = URL(string: "https://example.com/video.mp4")!
        let imageDestination = URL(fileURLWithPath: "/tmp/image.png")
        let videoDestination = URL(fileURLWithPath: "/tmp/video.mp4")
        let progress = XmaxStorageProgressRecorder()

        let image = try await manager.downloadImage(
            from: imageURL,
            to: imageDestination
        )
        let video = try await manager.downloadVideo(
            from: videoURL,
            to: videoDestination,
            progress: progress.handler
        )

        XCTAssertEqual(
            service.calls,
            [
                .download(
                    remoteURL: imageURL,
                    destinationURL: imageDestination,
                    hasProgress: false
                ),
                .download(
                    remoteURL: videoURL,
                    destinationURL: videoDestination,
                    hasProgress: true
                )
            ]
        )
        XCTAssertEqual(image, XmaxDownloadedFile(fileURL: imageDestination, byteCount: 512))
        XCTAssertEqual(video, XmaxDownloadedFile(fileURL: videoDestination, byteCount: 512))
        XCTAssertEqual(progress.values, [XmaxStorageProgressValue(completed: 512, total: 512)])
    }

    func testManagerMapsUnknownServiceErrorToXmaxError() async {
        let service = XmaxStorageServiceStub(
            error: NSError(
                domain: "XmaxStorageManagerTests",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected failure"]
            )
        )
        let manager = XmaxStorageManager(storageService: service)

        do {
            _ = try await manager.uploadVideo(
                Data("video".utf8),
                fileName: "video.mp4",
                contentType: "video/mp4"
            )
            XCTFail("Expected storage manager operation to fail")
        } catch {
            XCTAssertEqual(
                error as? XmaxError,
                XmaxError(
                    code: .internalError,
                    message: "Unexpected failure"
                )
            )
        }
    }
}

private enum XmaxStorageServiceCall: Equatable, Sendable {
    case uploadImage(
        data: Data,
        fileName: String,
        contentType: String,
        hasProgress: Bool
    )
    case uploadImageFile(
        fileURL: URL,
        contentType: String?,
        hasProgress: Bool
    )
    case uploadImageWithSafetyCheck(
        data: Data,
        fileName: String,
        contentType: String,
        hasProgress: Bool
    )
    case uploadImageFileWithSafetyCheck(
        fileURL: URL,
        contentType: String?,
        hasProgress: Bool
    )
    case uploadVideo(
        data: Data,
        fileName: String,
        contentType: String,
        hasProgress: Bool
    )
    case uploadVideoFile(
        fileURL: URL,
        contentType: String?,
        hasProgress: Bool
    )
    case download(
        remoteURL: URL,
        destinationURL: URL,
        hasProgress: Bool
    )
}

private final class XmaxStorageServiceStub:
    StorageServicing,
    @unchecked Sendable {

    /// Test configuration
    private let error: (any Error)?

    /// Concurrent state
    private let lock = NSLock()
    private var storedCalls: [XmaxStorageServiceCall] = []

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var calls: [XmaxStorageServiceCall] {
        lock.withLock { storedCalls }
    }

    func uploadImage(
        data: Data,
        fileName: String,
        contentType: String,
        progress: StorageProgressListener?
    ) async throws -> StoredFile {
        try uploadResult(
            call: .uploadImage(
                data: data,
                fileName: fileName,
                contentType: contentType,
                hasProgress: progress != nil
            ),
            progress: progress
        )
    }

    func uploadImageFile(
        fileURL: URL,
        contentType: String?,
        progress: StorageProgressListener?
    ) async throws -> StoredFile {
        try uploadResult(
            call: .uploadImageFile(
                fileURL: fileURL,
                contentType: contentType,
                hasProgress: progress != nil
            ),
            progress: progress
        )
    }

    func uploadImageWithSafetyCheck(
        data: Data,
        fileName: String,
        contentType: String,
        progress: StorageProgressListener?
    ) async throws -> StoredFile {
        try uploadResult(
            call: .uploadImageWithSafetyCheck(
                data: data,
                fileName: fileName,
                contentType: contentType,
                hasProgress: progress != nil
            ),
            progress: progress
        )
    }

    func uploadImageFileWithSafetyCheck(
        fileURL: URL,
        contentType: String?,
        progress: StorageProgressListener?
    ) async throws -> StoredFile {
        try uploadResult(
            call: .uploadImageFileWithSafetyCheck(
                fileURL: fileURL,
                contentType: contentType,
                hasProgress: progress != nil
            ),
            progress: progress
        )
    }

    func uploadVideo(
        data: Data,
        fileName: String,
        contentType: String,
        progress: StorageProgressListener?
    ) async throws -> StoredFile {
        try uploadResult(
            call: .uploadVideo(
                data: data,
                fileName: fileName,
                contentType: contentType,
                hasProgress: progress != nil
            ),
            progress: progress
        )
    }

    func uploadVideoFile(
        fileURL: URL,
        contentType: String?,
        progress: StorageProgressListener?
    ) async throws -> StoredFile {
        try uploadResult(
            call: .uploadVideoFile(
                fileURL: fileURL,
                contentType: contentType,
                hasProgress: progress != nil
            ),
            progress: progress
        )
    }

    func download(
        remoteURL: URL,
        destinationURL: URL,
        progress: StorageProgressListener?
    ) async throws -> DownloadedFile {
        try record(
            .download(
                remoteURL: remoteURL,
                destinationURL: destinationURL,
                hasProgress: progress != nil
            )
        )
        progress?(512, 512)
        return DownloadedFile(
            fileURL: destinationURL,
            byteCount: 512
        )
    }
}

private extension XmaxStorageServiceStub {
    func uploadResult(
        call: XmaxStorageServiceCall,
        progress: StorageProgressListener?
    ) throws -> StoredFile {
        try record(call)
        progress?(25, 100)
        return StoredFile(
            url: URL(string: "https://example.com/file")!,
            objectKey: "uploads/file",
            etag: "etag"
        )
    }

    func record(_ call: XmaxStorageServiceCall) throws {
        try lock.withLock {
            storedCalls.append(call)
            if let error {
                throw error
            }
        }
    }
}

private struct XmaxStorageProgressValue: Equatable, Sendable {
    let completed: Int64
    let total: Int64
}

private final class XmaxStorageProgressRecorder: @unchecked Sendable {

    /// Concurrent state
    private let lock = NSLock()
    private var storedValues: [XmaxStorageProgressValue] = []

    var values: [XmaxStorageProgressValue] {
        lock.withLock { storedValues }
    }

    var handler: XmaxStorageProgressHandler {
        { [weak self] progress in
            self?.lock.withLock {
                self?.storedValues.append(
                    XmaxStorageProgressValue(
                        completed: progress.completedUnitCount,
                        total: progress.totalUnitCount
                    )
                )
            }
        }
    }
}

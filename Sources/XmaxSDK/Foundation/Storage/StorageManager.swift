//
//  StorageManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@preconcurrency import QCloudCOSXML

/// Wraps third-party object storage uploads and HTTP file downloads.
final class StorageManager: StorageManaging, Sendable {

    /// The URL session for downloads.
    private let session: URLSession

    /// Creates a storage manager.
    init(
        session: URLSession = .shared
    ) {
        self.session = session
    }

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
        progress: StorageProgressListener? = nil
    ) async throws -> StoredFile {
        try Self.validateUpload(
            source: source,
            objectKey: objectKey,
            contentType: contentType,
            configuration: configuration
        )

        do {
            let service = try Self.makeStorageService(configuration: configuration)
            let request = try Self.makeUploadRequest(
                source: source,
                objectKey: objectKey,
                contentType: contentType,
                configuration: configuration
            )
            let operation = StorageUploadOperation(
                service: service,
                request: request,
                objectKey: objectKey,
                configuration: configuration,
                progress: progress
            )

            return try await operation.value()
        } catch let error as XmaxError {
            throw error
        } catch {
            throw Self.uploadError(error)
        }
    }

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
        progress: StorageProgressListener? = nil
    ) async throws -> DownloadedFile {
        let remoteScheme = remoteURL.scheme?.lowercased()
        guard remoteScheme == "https" || remoteScheme == "http" else {
            throw XmaxError(
                code: .downloadError,
                message: "Storage download URL must use HTTP or HTTPS"
            )
        }
        guard destinationURL.isFileURL else {
            throw XmaxError(
                code: .downloadError,
                message: "Storage download destination must be a file URL"
            )
        }

        do {
            let (data, response) = try await session.data(from: remoteURL)
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                throw XmaxError(
                    code: .downloadError,
                    message: statusCode.map {
                        "Storage download failed with HTTP \($0)"
                    } ?? "Storage download returned a non-HTTP response",
                    httpStatus: statusCode
                )
            }

            try data.write(
                to: destinationURL,
                options: .atomic
            )
            let byteCount = Int64(data.count)
            progress?(
                byteCount,
                byteCount
            )

            return DownloadedFile(
                fileURL: destinationURL,
                byteCount: byteCount
            )
        } catch let error as XmaxError {
            throw error
        } catch is CancellationError {
            throw Self.cancelledError(operation: "Storage download")
        } catch {
            let platformError = error as NSError
            if platformError.domain == NSURLErrorDomain,
                platformError.code == NSURLErrorCancelled
            {
                throw Self.cancelledError(operation: "Storage download")
            }

            throw XmaxError(
                code: .downloadError,
                message: platformError.localizedDescription
            )
        }
    }

    /// Builds the object access URL from the upload result or storage configuration.
    ///
    /// - Parameters:
    ///   - candidate: The candidate access URL from the upload response.
    ///   - configuration: The bucket, region, and endpoint configuration.
    ///   - objectKey: The uploaded object's key within the bucket.
    ///
    /// - Returns: The HTTP or HTTPS object URL.
    ///
    /// - Throws: An error on invalid endpoint, object key encoding failure, or URL construction failure.
    static func resolveObjectURL(
        candidate: String?,
        configuration: StorageConfiguration,
        objectKey: String
    ) throws -> URL {
        let location =
            candidate?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if location.hasPrefix("//"),
            let url = URL(string: "https:\(location)")
        {
            return url
        }
        if let url = URL(string: location) {
            let scheme = url.scheme?.lowercased()
            if scheme == "https" || scheme == "http" {
                return url
            }
        }

        let endpoint: String
        if configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            endpoint = "https://\(configuration.bucket).cos.\(configuration.region).myqcloud.com"
        } else {
            endpoint = try normalizedEndpoint(
                configuration.endpoint,
                bucket: configuration.bucket,
                preservePath: true
            ).absoluteString
        }

        let encodedObjectKey = try encodeObjectKey(objectKey)
        let baseURL = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/\(encodedObjectKey)") else {
            throw XmaxError(
                code: .uploadError,
                message: "Failed to build storage object URL"
            )
        }

        return url
    }

    /// Validates the upload source, object key, storage location, and temporary credentials.
    ///
    /// - Parameters:
    ///   - source: The data or local file to upload.
    ///   - objectKey: The destination object key.
    ///   - contentType: The upload content MIME type.
    ///   - configuration: The destination storage location and temporary credentials.
    ///
    /// - Throws: An error if upload configuration is invalid or the source file unavailable.
    private static func validateUpload(
        source: StorageUploadSource,
        objectKey: String,
        contentType: String,
        configuration: StorageConfiguration
    ) throws {
        let bucket = configuration.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = configuration.region.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let mimeType = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = configuration.credential

        guard matchesIdentifier(bucket) else {
            throw uploadError(message: "Storage bucket is invalid")
        }
        guard matchesIdentifier(region) else {
            throw uploadError(message: "Storage region is invalid")
        }
        guard !key.isEmpty else {
            throw uploadError(message: "Storage object key is invalid")
        }
        guard !mimeType.isEmpty else {
            throw uploadError(message: "Storage content type cannot be empty")
        }
        guard !credential.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !credential.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !credential.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw uploadError(message: "Storage temporary credential is incomplete")
        }

        if case let .file(url) = source {
            var isDirectory = ObjCBool(false)
            guard url.isFileURL,
                FileManager.default.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                ),
                !isDirectory.boolValue
            else {
                throw uploadError(message: "Storage upload file is unavailable")
            }
        }
    }

    /// Creates a COS service from endpoint configuration.
    ///
    /// - Parameter configuration: The storage region and endpoint.
    ///
    /// - Returns: The COS service for this upload.
    ///
    /// - Throws: An error if the endpoint is invalid or a platform endpoint cannot be created.
    private static func makeStorageService(
        configuration: StorageConfiguration
    ) throws -> QCloudCOSXMLService {
        let serviceConfiguration = QCloudServiceConfiguration()
        let endpointValue = configuration.endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if endpointValue.isEmpty {
            let endpoint = QCloudCOSXMLEndPoint()
            endpoint.regionName = configuration.region
            endpoint.useHTTPS = true
            serviceConfiguration.endpoint = endpoint
        } else {
            let url = try normalizedEndpoint(
                endpointValue,
                bucket: configuration.bucket,
                preservePath: false
            )
            guard let endpoint = QCloudEndPoint(literalURL: url) else {
                throw uploadError(message: "Storage endpoint is invalid")
            }
            endpoint.regionName = configuration.region
            endpoint.useHTTPS = url.scheme?.lowercased() == "https"
            serviceConfiguration.endpoint = endpoint
        }

        return QCloudCOSXMLService(
            configuration: serviceConfiguration
        )
    }

    /// Creates a COS upload request carrying temporary credentials.
    ///
    /// - Parameters:
    ///   - source: The data or local file to upload.
    ///   - objectKey: The destination object key.
    ///   - contentType: The upload content MIME type.
    ///   - configuration: The destination storage location and credentials.
    ///
    /// - Returns: The prepared object upload request.
    ///
    /// - Throws: An error if temporary credentials are invalid.
    private static func makeUploadRequest(
        source: StorageUploadSource,
        objectKey: String,
        contentType: String,
        configuration: StorageConfiguration
    ) throws -> QCloudPutObjectRequest<AnyObject> {
        let request = QCloudPutObjectRequest<AnyObject>()
        request.bucket = configuration.bucket
        request.object = objectKey
        request.contentType = contentType
        request.regionName = configuration.region
        request.credential = try makeCredential(configuration.credential)

        switch source {
        case let .data(data):
            request.body = data as NSData
        case let .file(url):
            request.body = url as NSURL
        }

        return request
    }

    /// Converts temporary access configuration to COS signing credentials.
    ///
    /// - Parameter configuration: The temporary keys and session token.
    ///
    /// - Returns: The credentials signing the current upload request.
    ///
    /// - Throws: An error if platform credential validation fails.
    private static func makeCredential(
        _ configuration: StorageCredential
    ) throws -> QCloudCredential {
        let credential = QCloudCredential()
        credential.secretID = configuration.accessKeyID
        credential.secretKey = configuration.secretAccessKey
        credential.token = configuration.sessionToken
        credential.startDate = Date(timeIntervalSinceNow: -60)
        credential.expirationDate = Date(timeIntervalSinceNow: 25 * 60)

        guard credential.valid else {
            throw uploadError(message: "Failed to create temporary storage credential")
        }

        return credential
    }

    /// Normalizes the storage endpoint and adds a bucket hostname prefix when needed.
    ///
    /// - Parameters:
    ///   - endpoint: The original endpoint text.
    ///   - bucket: The destination bucket name.
    ///   - preservePath: Whether to preserve endpoint paths and additional URL information.
    ///
    /// - Returns: The normalized HTTP or HTTPS endpoint.
    ///
    /// - Throws: An error if the endpoint scheme, host, or URL is invalid.
    private static func normalizedEndpoint(
        _ endpoint: String,
        bucket: String,
        preservePath: Bool
    ) throws -> URL {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.contains("://") ? value : "https://\(value)"
        guard var components = URLComponents(string: normalized),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty
        else {
            throw uploadError(message: "Storage endpoint is invalid")
        }

        if host.lowercased().hasPrefix("cos.") {
            components.host = "\(bucket).\(host)"
        }
        if !preservePath {
            components.path = ""
            components.query = nil
            components.fragment = nil
        }

        guard let url = components.url else {
            throw uploadError(message: "Storage endpoint is invalid")
        }
        return url
    }

    /// URL-encodes individual object key path segments.
    ///
    /// - Parameter objectKey: The original object key.
    ///
    /// - Returns: The encoded object key with path separators preserved.
    ///
    /// - Throws: An error if any path segment cannot be encoded.
    private static func encodeObjectKey(
        _ objectKey: String
    ) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        let encodedParts =
            objectKey
            .split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) }

        guard encodedParts.allSatisfy({ $0 != nil }) else {
            throw uploadError(message: "Storage object key cannot be URL encoded")
        }
        return encodedParts.compactMap { $0 }.joined(separator: "/")
    }

    /// Validates allowed characters in bucket or region identifiers.
    ///
    /// - Parameter value: The identifier to validate.
    ///
    /// - Returns: `true` for nonempty identifiers containing only letters, digits, dots, and hyphens.
    private static func matchesIdentifier(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value.range(
                of: #"^[A-Za-z0-9.-]+$"#,
                options: .regularExpression
            ) != nil
    }

    /// Converts platform errors to upload errors.
    ///
    /// - Parameter error: The underlying platform error.
    ///
    /// - Returns: An upload error retaining the localized description.
    private static func uploadError(
        _ error: any Error
    ) -> XmaxError {
        let platformError = error as NSError
        return uploadError(message: platformError.localizedDescription)
    }

    /// Creates an upload error.
    ///
    /// - Parameter message: The error description.
    ///
    /// - Returns: An upload error with the specified description.
    private static func uploadError(
        message: String
    ) -> XmaxError {
        XmaxError(
            code: .uploadError,
            message: message
        )
    }

    /// Creates a storage operation cancellation error.
    ///
    /// - Parameter operation: The cancelled operation name.
    ///
    /// - Returns: A cancellation error including the operation name.
    private static func cancelledError(
        operation: String
    ) -> XmaxError {
        XmaxError(
            code: .cancelled,
            message: "\(operation) was cancelled"
        )
    }
}

/// Retains one third-party upload request and resumes it exactly once on success, failure, or cancellation.
private final class StorageUploadOperation: @unchecked Sendable {

    /// The COS service performing the request.
    private let service: QCloudCOSXMLService

    /// The upload request.
    private let request: QCloudPutObjectRequest<AnyObject>

    /// The uploaded object key.
    private let objectKey: String

    /// The destination and authentication configuration.
    private let configuration: StorageConfiguration

    /// The upload byte progress handler.
    private let progress: StorageProgressListener?

    /// The upload start time.
    private let startedAt = Date()

    /// The lock protecting completion and its waiter.
    private let lock = NSLock()

    /// The continuation awaiting upload completion.
    private var continuation: CheckedContinuation<StoredFile, Error>?

    /// The result retained until a waiter is registered.
    private var pendingResult: Result<StoredFile, Error>?

    /// Whether the upload request has started.
    private var started = false

    /// Whether the upload has completed.
    private var completed = false

    /// Creates an asynchronous operation retaining one COS upload request.
    init(
        service: QCloudCOSXMLService,
        request: QCloudPutObjectRequest<AnyObject>,
        objectKey: String,
        configuration: StorageConfiguration,
        progress: StorageProgressListener?
    ) {
        self.service = service
        self.request = request
        self.objectKey = objectKey
        self.configuration = configuration
        self.progress = progress
    }

    /// Submits the upload request and awaits its single completion result.
    ///
    /// - Returns: The successfully uploaded object information.
    ///
    /// - Throws: An error on upload failure, result parsing failure, or cancellation.
    func value() async throws -> StoredFile {
        configureCallbacks()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
                startIfNeeded()
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Installs progress and completion callbacks and converts upload results consistently.
    private func configureCallbacks() {
        request.sendProcessBlock = { [progress] _, totalBytes, expectedBytes in
            progress?(
                totalBytes,
                max(expectedBytes, 0)
            )
        }
        request.finishBlock = { [weak self] result, error in
            guard let self else {
                return
            }

            if let error {
                let platformError = error as NSError
                XmaxLogger.storage.error(
                    message: "上传失败 (Upload Failed)\n"
                        + "├─ \(XmaxLogger.localized("错误域：", "Error Domain: "))\(platformError.domain)\n"
                        + "├─ \(XmaxLogger.localized("错误码：", "Error Code: "))\(platformError.code)\n"
                        + "├─ \(XmaxLogger.localized("错误信息：", "Error Message: "))\(platformError.localizedDescription)\n"
                        + "└─ \(XmaxLogger.localized("耗时：", "Duration: "))\(formatDuration())"
                )
                finish(
                    .failure(
                        XmaxError(
                            code: .uploadError,
                            message: platformError.localizedDescription
                        )
                    )
                )
                return
            }

            do {
                let headers = result as? [AnyHashable: Any]
                let location = Self.headerValue(
                    keys: ["Location", "location"],
                    headers: headers
                )
                let url = try StorageManager.resolveObjectURL(
                    candidate: location,
                    configuration: configuration,
                    objectKey: objectKey
                )
                let etag =
                    Self.headerValue(
                        keys: ["Etag", "ETag", "etag"],
                        headers: headers
                    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                finish(
                    .success(
                        StoredFile(
                            url: url,
                            objectKey: objectKey,
                            etag: etag.isEmpty ? nil : etag
                        )
                    )
                )
            } catch {
                finish(.failure(error))
            }
        }
    }

    /// Installs the continuation or immediately delivers a cached completion result.
    ///
    /// - Parameter continuation: The continuation awaiting the upload result.
    private func install(
        _ continuation: CheckedContinuation<StoredFile, Error>
    ) {
        lock.lock()
        let pendingResult = self.pendingResult
        self.pendingResult = nil
        if pendingResult == nil {
            self.continuation = continuation
        }
        lock.unlock()

        if let pendingResult {
            continuation.resume(with: pendingResult)
        }
    }

    /// Submits the upload request only if the operation has neither started nor finished.
    private func startIfNeeded() {
        lock.lock()
        guard !started, !completed else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        service.putObject(request)
    }

    /// Ends asynchronous waiting and cancels the underlying upload request.
    private func cancel() {
        finish(
            .failure(
                XmaxError(
                    code: .cancelled,
                    message: "Storage upload was cancelled"
                )
            )
        )
        request.cancel()
    }

    /// Records the first completion result and resumes the waiter.
    ///
    /// - Parameter result: The upload success information or failure error.
    private func finish(
        _ result: Result<StoredFile, Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()

        continuation?.resume(with: result)
    }

    /// Formats the current upload duration.
    ///
    /// - Returns: The duration text in milliseconds or seconds.
    private func formatDuration() -> String {
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        return String(
            format: "%.2f s",
            Double(milliseconds) / 1_000
        )
    }

    /// Reads string response headers in priority order.
    ///
    /// - Parameters:
    ///   - keys: The acceptable response header names.
    ///   - headers: The platform response headers; `nil` when unavailable.
    ///
    /// - Returns: The first matching string value, or `nil` if none is found.
    private static func headerValue(
        keys: [String],
        headers: [AnyHashable: Any]?
    ) -> String? {
        for key in keys {
            if let value = headers?[key] as? String {
                return value
            }
        }
        return nil
    }
}

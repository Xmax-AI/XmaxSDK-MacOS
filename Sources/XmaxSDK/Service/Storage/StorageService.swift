//
//  StorageService.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AVFoundation
import Foundation
import ImageIO

/// Coordinates image and video uploads, downloads, temporary credentials, and image safety checks.
final class StorageService: StorageServicing, Sendable {

    /// The credentials and safety-check API service.
    private let apiService: any ApiServicing

    /// The file transfer manager.
    private let storageManager: any StorageManaging

    /// The clock for object path generation.
    private let dateGenerator: @Sendable () -> Date

    /// The unique upload name generator.
    private let identifierGenerator: @Sendable () -> String

    /// Creates a media storage service with object path generation strategies.
    ///
    /// - Parameters:
    ///   - apiService: The API service requesting temporary credentials and safety checks.
    ///   - storageManager: The foundation component performing file uploads and downloads.
    ///   - dateGenerator: The current-time callback used to generate object paths.
    ///   - identifierGenerator: The random identifier callback used to generate object paths.
    init(
        apiService: any ApiServicing,
        storageManager: any StorageManaging,
        dateGenerator: @escaping @Sendable () -> Date = { Date() },
        identifierGenerator: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.apiService = apiService
        self.storageManager = storageManager
        self.dateGenerator = dateGenerator
        self.identifierGenerator = identifierGenerator
    }

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
        progress: StorageProgressListener? = nil
    ) async throws -> StoredFile {
        try await upload(
            source: .data(data),
            fileName: fileName,
            contentType: contentType,
            mediaType: .image,
            checksSafety: false,
            progress: progress
        )
    }

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
        contentType: String? = nil,
        progress: StorageProgressListener? = nil
    ) async throws -> StoredFile {
        let fileName = fileURL.lastPathComponent
        return try await upload(
            source: .file(fileURL),
            fileName: fileName,
            contentType: contentType ?? inferImageContentType(fileName),
            mediaType: .image,
            checksSafety: false,
            progress: progress
        )
    }

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
        progress: StorageProgressListener? = nil
    ) async throws -> StoredFile {
        try await upload(
            source: .data(data),
            fileName: fileName,
            contentType: contentType,
            mediaType: .image,
            checksSafety: true,
            progress: progress
        )
    }

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
        contentType: String? = nil,
        progress: StorageProgressListener? = nil
    ) async throws -> StoredFile {
        let fileName = fileURL.lastPathComponent
        return try await upload(
            source: .file(fileURL),
            fileName: fileName,
            contentType: contentType ?? inferImageContentType(fileName),
            mediaType: .image,
            checksSafety: true,
            progress: progress
        )
    }

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
        progress: StorageProgressListener? = nil
    ) async throws -> StoredFile {
        try await upload(
            source: .data(data),
            fileName: fileName,
            contentType: contentType,
            mediaType: .video,
            checksSafety: false,
            progress: progress
        )
    }

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
        contentType: String? = nil,
        progress: StorageProgressListener? = nil
    ) async throws -> StoredFile {
        let fileName = fileURL.lastPathComponent
        return try await upload(
            source: .file(fileURL),
            fileName: fileName,
            contentType: contentType ?? inferVideoContentType(fileName),
            mediaType: .video,
            checksSafety: false,
            progress: progress
        )
    }

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
        progress: StorageProgressListener? = nil
    ) async throws -> DownloadedFile {
        try validateDownload(
            remoteURL: remoteURL,
            destinationURL: destinationURL
        )
        return try await storageManager.download(
            remoteURL: remoteURL,
            destinationURL: destinationURL,
            progress: progress
        )
    }

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
        progress: StorageProgressListener? = nil
    ) async throws -> DownloadedFile {
        try validateDownload(
            remoteURL: remoteURL,
            destinationURL: destinationURL
        )
        return try await storageManager.download(
            remoteURL: remoteURL,
            destinationURL: destinationURL,
            progress: progress
        )
    }
}

private extension StorageService {

    /// Contains the object path prefix and temporary storage access configuration.
    struct TemporaryStorageConfiguration: Sendable {

        /// The upload object key prefix.
        let prefix: String

        /// The upload destination and credentials.
        let configuration: StorageConfiguration
    }

    /// Distinguishes image and video upload validation and metadata rules.
    enum StorageMediaType: String, Sendable {

        /// Image upload and safety verification.
        case image

        /// Video file upload.
        case video

        /// The media type name used in logs.
        var displayName: String {
            rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Receives temporary storage location and credential fields from the server.
    struct TemporaryStoragePayload: Decodable, Sendable {

        /// The COS bucket name.
        let bucket: String?

        /// The COS bucket region.
        let region: String?

        /// The object storage endpoint.
        let endpoint: String?

        /// The upload object key prefix.
        let prefix: String?

        /// The request's temporary authentication.
        let credentials: CredentialPayload?

        /// Defines encoding mappings between server fields and local properties.
        enum CodingKeys: CodingKey {

            /// The bucket name field.
            case bucket

            /// The storage region field.
            case region

            /// The storage endpoint field.
            case endpoint

            /// The object prefix field.
            case prefix

            /// The temporary credentials field.
            case credentials
        }

        /// Decodes temporary storage configuration, leaving unparseable fields nil.
        ///
        /// - Parameter decoder: The decoder supplying storage response fields.
        ///
        /// - Throws: A decoding error if the field container cannot be created.
        init(
            from decoder: any Decoder
        ) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bucket = try? container.decode(
                String.self,
                forKey: .bucket
            )
            region = try? container.decode(
                String.self,
                forKey: .region
            )
            endpoint = try? container.decode(
                String.self,
                forKey: .endpoint
            )
            prefix = try? container.decode(
                String.self,
                forKey: .prefix
            )
            credentials = try? container.decode(
                CredentialPayload.self,
                forKey: .credentials
            )
        }
    }

    /// Receives temporary object storage authentication fields.
    struct CredentialPayload: Decodable, Sendable {

        /// The temporary access key identifier.
        let accessKeyID: String?

        /// The temporary secret access key.
        let secretAccessKey: String?

        /// The temporary session token.
        let sessionToken: String?

        /// Defines encoding mappings between server fields and local properties.
        enum CodingKeys: String, CodingKey {

            /// The temporary access key identifier field.
            case accessKeyID = "accessKeyId"

            /// The temporary secret key field.
            case secretAccessKey

            /// The session token field.
            case sessionToken
        }

        /// Decodes temporary storage credentials, leaving unparseable fields nil.
        ///
        /// - Parameter decoder: The decoder supplying credential fields.
        ///
        /// - Throws: A decoding error if the field container cannot be created.
        init(
            from decoder: any Decoder
        ) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessKeyID = try? container.decode(
                String.self,
                forKey: .accessKeyID
            )
            secretAccessKey = try? container.decode(
                String.self,
                forKey: .secretAccessKey
            )
            sessionToken = try? container.decode(
                String.self,
                forKey: .sessionToken
            )
        }
    }

    /// Submits the remote image URL for checking.
    struct ImageSafetyRequest: Encodable, Sendable {

        /// The image URL to verify.
        let url: String
    }

    /// Receives image safety results and an approved image URL.
    struct ImageSafetyPayload: Decodable, Sendable {

        /// Whether the server approved the image.
        let safe: Bool?

        /// The server-provided image URL.
        let url: String?

        /// Defines encoding mappings between server fields and local properties.
        enum CodingKeys: CodingKey {

            /// The image safety result field.
            case safe

            /// The image URL field.
            case url
        }

        /// Decodes image safety check results.
        ///
        /// - Parameter decoder: The decoder supplying safety check responses.
        ///
        /// - Throws: A decoding error if the field container cannot be created.
        init(
            from decoder: any Decoder
        ) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            safe = try? container.decode(
                Bool.self,
                forKey: .safe
            )
            url = try? container.decode(
                String.self,
                forKey: .url
            )
        }
    }

    /// Validates media, retrieves credentials, uploads, and optionally checks image safety.
    ///
    /// - Parameters:
    ///   - source: The data or local file to upload.
    ///   - fileName: The original filename used to generate the object path.
    ///   - contentType: The uploaded file MIME type.
    ///   - mediaType: The media type used for content validation and dimension reading.
    ///   - checksSafety: Whether to check image safety after upload.
    ///   - progress: The byte progress callback; `nil` disables reporting.
    ///
    /// - Returns: The remote file information after upload and required safety checks succeed.
    ///
    /// - Throws: An error on invalid media parameters, credential or upload failure, safety check failure, or
    ///   cancellation.
    func upload(
        source: StorageUploadSource,
        fileName: String,
        contentType: String,
        mediaType: StorageMediaType,
        checksSafety: Bool,
        progress: StorageProgressListener?
    ) async throws -> StoredFile {
        let startedAt = Date()
        do {
            let safeName = try validateUpload(
                source: source,
                fileName: fileName,
                contentType: contentType,
                mediaType: mediaType
            )
            let byteCount = try sourceByteCount(source)
            let resolution = await readResolution(
                source: source,
                mediaType: mediaType
            )
            XmaxLogger.storage.info(
                message: "开始上传 (Upload Started)\n"
                    + "├─ \(XmaxLogger.localized("类型：", "Type: "))\(mediaType.rawValue)\n"
                    + "├─ \(XmaxLogger.localized("分辨率：", "Resolution: "))\(resolution)\n"
                    + "├─ \(XmaxLogger.localized("大小：", "Size: "))\(formatByteCount(byteCount))\n"
                    + "└─ \(XmaxLogger.localized("安全检测：", "Safety Check: "))\(checksSafety)"
            )

            let temporary = try await fetchStorageConfiguration()
            let objectKey = makeObjectKey(
                prefix: temporary.prefix,
                fileName: safeName
            )
            let stored = try await storageManager.upload(
                source: source,
                objectKey: objectKey,
                contentType: contentType.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                configuration: temporary.configuration,
                progress: progress
            )

            let result: StoredFile
            if checksSafety {
                let checkedURL = try await checkImage(stored.url)
                result = StoredFile(
                    url: checkedURL,
                    objectKey: stored.objectKey,
                    etag: stored.etag
                )
            } else {
                result = stored
            }

            XmaxLogger.storage.info(
                message: "上传完成 (Upload Completed)\n"
                    + "├─ \(XmaxLogger.localized("地址：", "URL: "))\(result.url.absoluteString)\n"
                    + "└─ \(XmaxLogger.localized("耗时：", "Duration: "))\(formatDuration(since: startedAt))"
            )
            return result
        } catch let error as XmaxError {
            if error.code != .uploadError {
                logUploadFailure(
                    error,
                    startedAt: startedAt
                )
            }
            throw error
        } catch is CancellationError {
            let error = XmaxError(
                code: .cancelled,
                message: "Storage upload was cancelled"
            )
            logUploadFailure(
                error,
                startedAt: startedAt
            )
            throw error
        } catch {
            let uploadError = XmaxError(
                code: .uploadError,
                message: ErrorMessageFormatter.format(error)
            )
            throw uploadError
        }
    }

    /// Retrieves and validates temporary storage configuration.
    ///
    /// - Returns: The object path prefix and complete temporary access configuration.
    ///
    /// - Throws: An error on API request failure or invalid required credential fields.
    func fetchStorageConfiguration() async throws -> TemporaryStorageConfiguration {
        let payload = try await apiService.get(
            "/cos/sts",
            as: TemporaryStoragePayload.self
        )
        let message = "Invalid storage credential payload"
        guard let bucket = requiredString(payload.bucket),
            let region = requiredString(payload.region),
            let endpoint = normalizedString(payload.endpoint),
            let prefix = normalizedString(payload.prefix),
            let credentials = payload.credentials,
            let accessKeyID = requiredString(credentials.accessKeyID),
            let secretAccessKey = requiredString(
                credentials.secretAccessKey
            ),
            let sessionToken = requiredString(credentials.sessionToken)
        else {
            throw XmaxError(
                code: .apiError,
                message: message
            )
        }

        return TemporaryStorageConfiguration(
            prefix: prefix,
            configuration: StorageConfiguration(
                bucket: bucket,
                region: region,
                endpoint: endpoint,
                credential: StorageCredential(
                    accessKeyID: accessKeyID,
                    secretAccessKey: secretAccessKey,
                    sessionToken: sessionToken
                )
            )
        )
    }

    /// Requests image safety validation and returns the approved URL.
    ///
    /// - Parameter url: The uploaded image URL.
    ///
    /// - Returns: The image URL approved by the server.
    ///
    /// - Throws: An error on request failure, invalid check result, or rejected image.
    func checkImage(
        _ url: URL
    ) async throws -> URL {
        let payload = try await apiService.post(
            "/cos/image/check",
            body: ImageSafetyRequest(url: url.absoluteString),
            as: ImageSafetyPayload.self
        )
        let message = "Invalid image safety check payload"
        guard let safe = payload.safe else {
            throw XmaxError(
                code: .apiError,
                message: message
            )
        }
        guard safe else {
            throw XmaxError(
                code: .unsafeImage,
                message: "The image did not pass the safety check"
            )
        }
        guard let value = normalizedString(payload.url),
            let checkedURL = URL(string: value),
            isHTTPURL(checkedURL)
        else {
            throw XmaxError(
                code: .apiError,
                message: message
            )
        }
        return checkedURL
    }

    /// Checks upload source and media type and creates a safe filename.
    ///
    /// - Parameters:
    ///   - source: The data or local file to upload.
    ///   - fileName: The filename to normalize.
    ///   - contentType: The MIME type that must match the media type.
    ///   - mediaType: The permitted media type for this upload.
    ///
    /// - Returns: The safe filename used in object paths.
    ///
    /// - Throws: An error on empty or invalid source, MIME mismatch, or filename without valid characters.
    func validateUpload(
        source: StorageUploadSource,
        fileName: String,
        contentType: String,
        mediaType: StorageMediaType
    ) throws -> String {
        switch source {
        case .data(let data):
            guard !data.isEmpty else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "\(mediaType.displayName) data cannot be empty"
                )
            }
        case .file(let fileURL):
            var isDirectory = ObjCBool(false)
            guard fileURL.isFileURL,
                FileManager.default.fileExists(
                    atPath: fileURL.path,
                    isDirectory: &isDirectory
                ),
                !isDirectory.boolValue
            else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "\(mediaType.displayName) file URL must reference " + "an existing file"
                )
            }
        }

        let normalizedContentType =
            contentType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedContentType.hasPrefix("\(mediaType.rawValue)/") else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "\(mediaType.displayName) content type must begin " + "with \(mediaType.rawValue)/"
            )
        }

        let safeName = sanitizeFileName(fileName)
        guard !safeName.isEmpty else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "\(mediaType.displayName) file name cannot be empty"
            )
        }
        return safeName
    }

    /// Validates the remote download URL and local destination.
    ///
    /// - Parameters:
    ///   - remoteURL: The HTTP or HTTPS URL with a hostname.
    ///   - destinationURL: The local destination file URL.
    ///
    /// - Throws: A configuration error if download or destination URLs are invalid.
    func validateDownload(
        remoteURL: URL,
        destinationURL: URL
    ) throws {
        guard isHTTPURL(remoteURL) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Invalid download URL"
            )
        }
        guard destinationURL.isFileURL, !destinationURL.path.isEmpty else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Download destination URL must be a file URL"
            )
        }
    }

    /// Infers image MIME type from its extension.
    ///
    /// - Parameter fileName: The filename including an image extension.
    ///
    /// - Returns: The image MIME type for the extension.
    ///
    /// - Throws: A configuration error for unsupported extensions.
    func inferImageContentType(
        _ fileName: String
    ) throws -> String {
        try inferContentType(
            fileName: fileName,
            types: [
                "jpg": "image/jpeg",
                "jpeg": "image/jpeg",
                "jpe": "image/jpeg",
                "png": "image/png",
                "gif": "image/gif",
                "webp": "image/webp",
                "heic": "image/heic",
                "heif": "image/heif",
                "bmp": "image/bmp",
                "svg": "image/svg+xml",
                "tif": "image/tiff",
                "tiff": "image/tiff",
                "avif": "image/avif"
            ],
            mediaType: "image"
        )
    }

    /// Infers video MIME type from its extension.
    ///
    /// - Parameter fileName: The filename including a video extension.
    ///
    /// - Returns: The video MIME type for the extension.
    ///
    /// - Throws: A configuration error for unsupported extensions.
    func inferVideoContentType(
        _ fileName: String
    ) throws -> String {
        try inferContentType(
            fileName: fileName,
            types: [
                "mp4": "video/mp4",
                "mov": "video/quicktime",
                "m4v": "video/x-m4v",
                "webm": "video/webm",
                "avi": "video/x-msvideo",
                "mkv": "video/x-matroska",
                "3gp": "video/3gpp",
                "3g2": "video/3gpp2",
                "ts": "video/mp2t"
            ],
            mediaType: "video"
        )
    }

    /// Looks up file MIME type in an extension mapping.
    ///
    /// - Parameters:
    ///   - fileName: The filename including extension.
    ///   - types: The lowercase extension-to-MIME mapping.
    ///   - mediaType: The media type name used in errors.
    ///
    /// - Returns: The MIME type for the file extension.
    ///
    /// - Throws: A configuration error if the extension is absent from the mapping.
    func inferContentType(
        fileName: String,
        types: [String: String],
        mediaType: String
    ) throws -> String {
        let fileExtension = URL(fileURLWithPath: fileName)
            .pathExtension
            .lowercased()
        guard let contentType = types[fileExtension] else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Unable to infer \(mediaType) content type from " + "file extension"
            )
        }
        return contentType
    }

    /// Replaces unsupported filename characters with underscores and trims boundary separators.
    ///
    /// - Parameter value: The original filename to normalize.
    ///
    /// - Returns: A filename containing only letters, digits, and permitted separators; empty without valid characters.
    func sanitizeFileName(
        _ value: String
    ) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(CharacterSet(charactersIn: "._-"))
        let components =
            value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: allowed.inverted)
        var result = components.joined(separator: "_")
        while result.contains("__") {
            result = result.replacingOccurrences(
                of: "__",
                with: "_"
            )
        }
        return result.trimmingCharacters(
            in: CharacterSet(charactersIn: "._-")
        )
    }

    /// Combines server prefix, millisecond timestamp, random identifier, and filename into an object path.
    ///
    /// - Parameters:
    ///   - prefix: The writable object path prefix allowed by the server.
    ///   - fileName: The validated safe filename.
    ///
    /// - Returns: The complete object path for this upload.
    func makeObjectKey(
        prefix: String,
        fileName: String
    ) -> String {
        let milliseconds = Int64(
            dateGenerator().timeIntervalSince1970 * 1_000
        )
        let identifier = identifierGenerator().lowercased()
        return "\(prefix)\(milliseconds)_\(identifier)_\(fileName)"
    }

    /// Reads the upload source byte count.
    ///
    /// - Parameter source: The data or local file to upload.
    ///
    /// - Returns: The data length or file size in bytes.
    ///
    /// - Throws: A filesystem error if local file attributes cannot be read.
    func sourceByteCount(
        _ source: StorageUploadSource
    ) throws -> Int64 {
        switch source {
        case .data(let data):
            return Int64(data.count)
        case .file(let fileURL):
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fileURL.path
            )
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    /// Reads media display dimensions for upload logging, using a placeholder if unavailable.
    ///
    /// - Parameters:
    ///   - source: The data or file to upload.
    ///   - mediaType: The media type selecting image or video metadata reading.
    ///
    /// - Returns: The width and height text; `--` if unavailable.
    func readResolution(
        source: StorageUploadSource,
        mediaType: StorageMediaType
    ) async -> String {
        do {
            switch mediaType {
            case .image:
                return try readImageResolution(source)
            case .video:
                return try await readVideoResolution(source)
            }
        } catch {
            return "--"
        }
    }

    /// Reads pixel dimensions from the image header.
    ///
    /// - Parameter source: The encoded image data or local image file.
    ///
    /// - Returns: The image width and height text; `--` without metadata.
    ///
    /// - Throws: None; returns a placeholder if image properties cannot be read.
    func readImageResolution(
        _ source: StorageUploadSource
    ) throws -> String {
        let imageSource: CGImageSource?
        switch source {
        case .data(let data):
            imageSource = CGImageSourceCreateWithData(
                data as CFData,
                nil
            )
        case .file(let fileURL):
            imageSource = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                nil
            )
        }
        guard let imageSource,
            let properties = CGImageSourceCopyPropertiesAtIndex(
                imageSource,
                0,
                nil
            ) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            return "--"
        }
        return formatResolution(
            width: width.intValue,
            height: height.intValue
        )
    }

    /// Reads local video display dimensions after rotation transforms.
    ///
    /// - Parameter source: The video upload source; dimensions are not read for in-memory data.
    ///
    /// - Returns: The display width and height text; `--` for non-file sources or missing video tracks.
    ///
    /// - Throws: A media read error if video tracks or transforms cannot be loaded.
    func readVideoResolution(
        _ source: StorageUploadSource
    ) async throws -> String {
        guard case .file(let fileURL) = source else {
            return "--"
        }
        let asset = AVURLAsset(url: fileURL)
        guard
            let track = try await asset.loadTracks(
                withMediaType: .video
            ).first
        else {
            return "--"
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformedSize = naturalSize.applying(transform)
        return formatResolution(
            width: Int(abs(transformedSize.width).rounded()),
            height: Int(abs(transformedSize.height).rounded())
        )
    }

    /// Formats valid dimensions for logging.
    ///
    /// - Parameters:
    ///   - width: The media width in pixels.
    ///   - height: The media height in pixels.
    ///
    /// - Returns: The width and height text; `--` for nonpositive dimensions.
    func formatResolution(
        width: Int,
        height: Int
    ) -> String {
        guard width > 0, height > 0 else {
            return "--"
        }
        return "\(width) × \(height)"
    }

    /// Selects readable units and formats file size.
    ///
    /// - Parameter byteCount: The file size in bytes.
    ///
    /// - Returns: The size text in B, KB, MB, or GB.
    func formatByteCount(
        _ byteCount: Int64
    ) -> String {
        let count = Double(byteCount)
        if byteCount < 1_024 {
            return "\(byteCount) B"
        }
        if byteCount < 1_024 * 1_024 {
            return String(
                format: "%.1f KB",
                count / 1_024
            )
        }
        if byteCount < 1_024 * 1_024 * 1_024 {
            return String(
                format: "%.2f MB",
                count / (1_024 * 1_024)
            )
        }
        return String(
            format: "%.2f GB",
            count / (1_024 * 1_024 * 1_024)
        )
    }

    /// Calculates operation duration and selects milliseconds or seconds.
    ///
    /// - Parameter startedAt: The operation start time.
    ///
    /// - Returns: The formatted duration text.
    func formatDuration(
        since startedAt: Date
    ) -> String {
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        return String(
            format: "%.2f s",
            Double(milliseconds) / 1_000
        )
    }

    /// Logs the upload error code, reason, and duration.
    ///
    /// - Parameters:
    ///   - error: The upload error to log.
    ///   - startedAt: The upload operation start time.
    func logUploadFailure(
        _ error: XmaxError,
        startedAt: Date
    ) {
        XmaxLogger.storage.error(
            message: "上传失败 (Upload Failed)\n"
                + "├─ \(XmaxLogger.localized("错误码：", "Error Code: "))\(error.code.rawValue)\n"
                + "├─ \(XmaxLogger.localized("原因：", "Reason: "))\(error.message)\n"
                + "└─ \(XmaxLogger.localized("耗时：", "Duration: "))\(formatDuration(since: startedAt))"
        )
    }

    /// Trims an optional string.
    ///
    /// - Parameter value: The optional string to normalize.
    ///
    /// - Returns: The normalized string; preserves `nil`.
    func normalizedString(
        _ value: String?
    ) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a nonempty trimmed string.
    ///
    /// - Parameter value: The optional field to validate.
    ///
    /// - Returns: The nonempty field value; `nil` if missing or whitespace-only.
    func requiredString(
        _ value: String?
    ) -> String? {
        guard let value = normalizedString(value), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Checks that a URL uses HTTP or HTTPS with a valid hostname.
    ///
    /// - Parameter url: The URL to check.
    ///
    /// - Returns: `true` if the scheme and hostname satisfy requirements.
    func isHTTPURL(
        _ url: URL
    ) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "https" || scheme == "http")
            && url.host?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false
    }
}

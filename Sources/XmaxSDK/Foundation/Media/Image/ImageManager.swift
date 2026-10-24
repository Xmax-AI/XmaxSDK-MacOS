//
//  ImageManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import ImageIO

/// Provides internal image decoding through ImageIO.
final class ImageManager: ImageManaging, Sendable {

    /// Decodes image data, applies orientation, and returns reusable pixel data.
    ///
    /// - Parameter data: Encoded image data in JPEG, PNG, or another supported format.
    ///
    /// - Returns: The decoded image with source orientation applied.
    ///
    /// - Throws: An error on empty data, unsupported formats, or image decoding failure.
    func decode(
        _ data: Data
    ) throws -> any DecodedImage {
        guard !data.isEmpty,
            let source = CGImageSourceCreateWithData(
                data as CFData,
                nil
            )
        else {
            throw Self.processingError("Failed to create image source from data")
        }
        guard CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
            ) as? [CFString: Any],
            let rawWidth = properties[
                kCGImagePropertyPixelWidth
            ] as? NSNumber,
            let rawHeight = properties[
                kCGImagePropertyPixelHeight
            ] as? NSNumber
        else {
            throw Self.processingError("Failed to read image metadata")
        }

        let maximumPixelSize = max(rawWidth.intValue, rawHeight.intValue)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard maximumPixelSize > 0,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        else {
            throw Self.processingError("Failed to decode image")
        }
        return CoreGraphicsDecodedImage(image: image)
    }

    /// Creates an image processing error.
    ///
    /// - Parameter message: A readable image processing failure description.
    ///
    /// - Returns: An SDK error with the media error code.
    private static func processingError(
        _ message: String
    ) -> XmaxError {
        XmaxError(
            code: .mediaError,
            message: message
        )
    }
}

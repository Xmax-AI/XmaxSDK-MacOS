//
//  DecodedImage.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
@preconcurrency import CoreGraphics

/// An internal SDK image with orientation applied and pixels decoded.
protocol DecodedImage: Sendable {

    /// The decoded image dimensions in pixels.
    var size: CGSize { get }

    /// Center-crops and scales the image to the target aspect ratio, creating a reusable video frame.
    ///
    /// - Parameters:
    ///   - width: The target frame width in pixels.
    ///   - height: The target frame height in pixels.
    ///
    /// - Returns: A BGRA frame with a buffer reuse identifier and an initial timestamp of zero.
    ///
    /// - Throws: An error on invalid dimensions, memory size overflow, or cropping or pixel drawing failure.
    func makeVideoFrame(
        width: Int,
        height: Int
    ) throws -> VideoFrame
}

/// Retains an oriented Core Graphics image and produces video frames.
final class CoreGraphicsDecodedImage: DecodedImage, @unchecked Sendable {

    /// The decoded image pixels.
    private let image: CGImage

    /// The decoded dimensions, in pixels.
    let size: CGSize

    /// Retains a Core Graphics image with orientation applied.
    ///
    /// - Parameter image: The pixel image used for subsequent cropping and scaling.
    init(
        image: CGImage
    ) {
        self.image = image
        size = CGSize(
            width: image.width,
            height: image.height
        )
    }

    /// Center-crops and scales the image to the target aspect ratio, creating a reusable video frame.
    ///
    /// - Parameters:
    ///   - width: The target frame width in pixels.
    ///   - height: The target frame height in pixels.
    ///
    /// - Returns: A BGRA frame with a buffer reuse identifier and an initial timestamp of zero.
    ///
    /// - Throws: An error on invalid dimensions, memory size overflow, or cropping or pixel drawing failure.
    func makeVideoFrame(
        width: Int,
        height: Int
    ) throws -> VideoFrame {
        guard width > 0, height > 0 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Image width and height must be finite numbers " + "greater than zero"
            )
        }

        let cropRect = Self.centerCropRect(
            sourceWidth: image.width,
            sourceHeight: image.height,
            targetWidth: width,
            targetHeight: height
        )
        let sourceImage: CGImage
        if cropRect.width == CGFloat(image.width),
            cropRect.height == CGFloat(image.height)
        {
            sourceImage = image
        } else {
            guard let croppedImage = image.cropping(to: cropRect) else {
                throw Self.processingError("Failed to crop source image")
            }
            sourceImage = croppedImage
        }

        let (pixelCount, pixelOverflow) =
            width
            .multipliedReportingOverflow(by: height)
        guard !pixelOverflow else {
            throw Self.processingError("Image dimensions are too large")
        }
        let (byteCount, byteOverflow) =
            pixelCount
            .multipliedReportingOverflow(by: 4)
        guard !byteOverflow else {
            throw Self.processingError("Image dimensions are too large")
        }

        let bytesPerRow = try Self.bytesPerRow(width: width)
        var data = Data(count: byteCount)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let didRender = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let address = bytes.baseAddress,
                let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                )
            else {
                return false
            }

            context.interpolationQuality = .high
            context.draw(
                sourceImage,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: height
                )
            )
            return true
        }
        guard didRender else {
            throw Self.processingError("Failed to create image frame data")
        }

        return try VideoFrame(
            format: VideoFormat(
                width: width,
                height: height,
                pixelFormat: .bgra
            ),
            timestampUs: 0,
            planes: [
                VideoFramePlane(
                    data: data,
                    stride: bytesPerRow
                )
            ],
            bufferReuseID: UUID()
        )
    }

    /// Calculates a centered crop preserving the target aspect ratio.
    ///
    /// - Parameters:
    ///   - sourceWidth: The source image width in pixels.
    ///   - sourceHeight: The source image height in pixels.
    ///   - targetWidth: The target output width in pixels.
    ///   - targetHeight: The target output height in pixels.
    ///
    /// - Returns: An integer-pixel crop rectangle in source image coordinates.
    static func centerCropRect(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> CGRect {
        let targetAspectRatio = Double(targetWidth) / Double(targetHeight)
        let sourceAspectRatio = Double(sourceWidth) / Double(sourceHeight)
        var cropWidth = sourceWidth
        var cropHeight = sourceHeight

        if sourceAspectRatio > targetAspectRatio {
            cropWidth = max(
                Int(floor(Double(sourceHeight) * targetAspectRatio)),
                1
            )
        } else if sourceAspectRatio < targetAspectRatio {
            cropHeight = max(
                Int(floor(Double(sourceWidth) / targetAspectRatio)),
                1
            )
        }

        return CGRect(
            x: CGFloat((sourceWidth - cropWidth) / 2),
            y: CGFloat((sourceHeight - cropHeight) / 2),
            width: CGFloat(cropWidth),
            height: CGFloat(cropHeight)
        )
    }
}

private extension CoreGraphicsDecodedImage {

    /// Calculates the BGRA image byte count per row.
    ///
    /// - Parameter width: The image width in pixels.
    ///
    /// - Returns: The total row byte count for four-byte pixels.
    ///
    /// - Throws: A media error if width calculation overflows.
    static func bytesPerRow(
        width: Int
    ) throws -> Int {
        let (value, overflow) = width.multipliedReportingOverflow(by: 4)
        guard !overflow else {
            throw processingError("Image dimensions are too large")
        }
        return value
    }

    /// Creates an image processing error.
    ///
    /// - Parameter message: A readable image processing failure description.
    ///
    /// - Returns: An SDK error with the media error code.
    static func processingError(
        _ message: String
    ) -> XmaxError {
        XmaxError(
            code: .mediaError,
            message: message
        )
    }
}

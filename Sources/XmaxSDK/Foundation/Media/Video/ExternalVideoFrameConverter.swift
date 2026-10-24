//
//  ExternalVideoFrameConverter.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreVideo
import Foundation

/// Copies external pixel buffers into owned neutral frames without changing their pixels.
enum ExternalVideoFrameConverter {

    /// Validates format and dimensions and copies pixel planes before returning.
    ///
    /// - Parameters:
    ///   - pixelBuffer: An upright NV12 video-range or BGRA buffer.
    ///   - videoFormat: The negotiated input format.
    ///   - timestampUs: The frame timestamp in monotonic microseconds.
    ///
    /// - Returns: A frame owning its pixel bytes, including any source row padding.
    ///
    /// - Throws: A media error for unsupported formats, dimensions, or inaccessible pixels.
    static func convert(
        _ pixelBuffer: CVPixelBuffer,
        videoFormat: RealtimeVideoFormat,
        timestampUs: Int64
    ) throws -> VideoFrame {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width == videoFormat.width, height == videoFormat.height else {
            throw invalid("External frame dimensions must match sink.videoFormat")
        }
        let format: VideoPixelFormat
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: format = .nv12
        case kCVPixelFormatType_32BGRA: format = .bgra
        default: throw invalid("External video requires NV12 video-range (420v) or BGRA pixels")
        }
        guard
            CVPixelBufferLockBaseAddress(
                pixelBuffer,
                .readOnly
            ) == kCVReturnSuccess
        else {
            throw invalid("External video pixels could not be locked")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(
                pixelBuffer,
                .readOnly
            )
        }

        let planes: [VideoFramePlane]
        if format == .nv12 {
            guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
                throw invalid("External NV12 video requires two pixel planes")
            }
            planes = try (0..<2).map { index in
                let rows = index == 0 ? height : height / 2
                guard
                    CVPixelBufferGetWidthOfPlane(
                        pixelBuffer,
                        index
                    ) == (index == 0 ? width : width / 2),
                    CVPixelBufferGetHeightOfPlane(
                        pixelBuffer,
                        index
                    ) == rows
                else {
                    throw invalid("External NV12 plane dimensions are invalid")
                }
                return try copyPlane(
                    CVPixelBufferGetBaseAddressOfPlane(
                        pixelBuffer,
                        index
                    ),
                    stride: CVPixelBufferGetBytesPerRowOfPlane(
                        pixelBuffer,
                        index
                    ),
                    rows: rows,
                    minimumStride: width
                )
            }
        } else {
            let (rowBytes, overflow) = width.multipliedReportingOverflow(by: 4)
            guard !overflow else { throw invalid("External BGRA row size is invalid") }
            planes = [
                try copyPlane(
                    CVPixelBufferGetBaseAddress(pixelBuffer),
                    stride: CVPixelBufferGetBytesPerRow(pixelBuffer),
                    rows: height,
                    minimumStride: rowBytes
                )
            ]
        }
        return try VideoFrame(
            format: VideoFormat(
                width: width,
                height: height,
                pixelFormat: format
            ),
            timestampUs: timestampUs,
            planes: planes
        )
    }

    /// Copies a validated plane while preserving its row stride.
    private static func copyPlane(
        _ address: UnsafeMutableRawPointer?,
        stride: Int,
        rows: Int,
        minimumStride: Int
    ) throws -> VideoFramePlane {
        let (count, overflow) = stride.multipliedReportingOverflow(by: rows)
        guard let address, stride >= minimumStride, rows > 0, !overflow, count > 0 else {
            throw invalid("External video plane layout is invalid")
        }
        return try VideoFramePlane(
            data: Data(
                bytes: address,
                count: count
            ),
            stride: stride
        )
    }

    /// Creates a consistent external media validation error.
    private static func invalid(
        _ message: String
    ) -> XmaxError {
        XmaxError(
            code: .mediaError,
            message: message
        )
    }
}

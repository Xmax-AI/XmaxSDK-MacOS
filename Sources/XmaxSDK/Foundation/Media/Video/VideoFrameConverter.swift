//
//  VideoFrameConverter.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Accelerate
import CoreVideo
import Foundation

/// Crops and scales upright pixels into owned storage.
enum VideoFrameConverter {

    /// Center-crops and scales pixels to the requested dimensions.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The source video-range NV12 or BGRA buffer.
    ///   - outputWidth: The positive, even output width, in pixels.
    ///   - outputHeight: The positive, even output height, in pixels.
    ///   - timestampUs: The output timestamp, in microseconds.
    ///   - outputPixelBuffer: An exclusive destination buffer, or nil for owned byte planes.
    ///
    /// - Returns: An independently owned frame retaining the input pixel format.
    ///
    /// - Throws: An error if the format, planes, or dimensions are invalid or conversion fails.
    static func convert(
        pixelBuffer: CVPixelBuffer,
        outputWidth: Int,
        outputHeight: Int,
        timestampUs: Int64,
        outputPixelBuffer: CVPixelBuffer? = nil
    ) throws -> VideoFrame {
        guard outputPixelBuffer !== pixelBuffer else {
            throw mediaError("Video source and destination buffers must be distinct")
        }
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA:
            return try convertBGRA(
                pixelBuffer,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                timestampUs: timestampUs,
                outputPixelBuffer: outputPixelBuffer
            )
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return try convertNV12(
                pixelBuffer: pixelBuffer,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                timestampUs: timestampUs,
                outputPixelBuffer: outputPixelBuffer
            )
        default:
            throw mediaError("External video requires NV12 video-range (420v) or BGRA pixels")
        }
    }

    /// Creates a cropped and scaled frame from video-range NV12.
    private static func convertNV12(
        pixelBuffer: CVPixelBuffer,
        outputWidth: Int,
        outputHeight: Int,
        timestampUs: Int64,
        outputPixelBuffer: CVPixelBuffer?
    ) throws -> VideoFrame {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw mediaError("External video requires video-range NV12 or BGRA pixels")
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0,
            height > 0,
            width.isMultiple(of: 2),
            height.isMultiple(of: 2),
            outputWidth > 0,
            outputHeight > 0,
            outputWidth.isMultiple(of: 2),
            outputHeight.isMultiple(of: 2),
            CVPixelBufferGetWidthOfPlane(
                pixelBuffer,
                0
            ) >= width,
            CVPixelBufferGetHeightOfPlane(
                pixelBuffer,
                0
            ) >= height,
            CVPixelBufferGetWidthOfPlane(
                pixelBuffer,
                1
            ) >= width / 2,
            CVPixelBufferGetHeightOfPlane(
                pixelBuffer,
                1
            ) >= height / 2
        else {
            throw mediaError("NV12 video dimensions are invalid")
        }

        let lockStatus = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard lockStatus == kCVReturnSuccess else {
            throw mediaError("Failed to lock NV12 video data")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(
                pixelBuffer,
                .readOnly
            )
        }

        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            0
        )
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            1
        )
        guard lumaStride >= width,
            chromaStride >= width,
            let lumaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                0
            ),
            let chromaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                1
            )
        else {
            throw mediaError("NV12 video plane layout is invalid")
        }

        let crop = centerCrop(
            sourceWidth: width,
            sourceHeight: height,
            targetWidth: outputWidth,
            targetHeight: outputHeight
        )

        let format = try VideoFormat(width: outputWidth, height: outputHeight, pixelFormat: .nv12)
        return try renderFrame(
            format: format,
            timestampUs: timestampUs,
            outputPixelBuffer: outputPixelBuffer
        ) { targetLuma, targetChroma in
            guard let targetChroma else { throw mediaError("NV12 destination has no chroma plane") }
            try scale(
                source: vImage_Buffer(
                    data: lumaBaseAddress.advanced(by: crop.y * lumaStride + crop.x),
                    height: vImagePixelCount(crop.height),
                    width: vImagePixelCount(crop.width),
                    rowBytes: lumaStride
                ),
                destination: targetLuma,
                bytesPerPixel: 1
            )
            try scale(
                source: vImage_Buffer(
                    data: chromaBaseAddress.advanced(by: crop.y / 2 * chromaStride + crop.x),
                    height: vImagePixelCount(crop.height / 2),
                    width: vImagePixelCount(crop.width / 2),
                    rowBytes: chromaStride
                ),
                destination: targetChroma,
                bytesPerPixel: 2
            )
        }
    }

    /// Creates a cropped and scaled frame from BGRA pixels.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The BGRA pixel buffer.
    ///   - outputWidth: The final display width.
    ///   - outputHeight: The final display height.
    ///   - timestampUs: The monotonic timestamp, in microseconds.
    ///   - outputPixelBuffer: An exclusive destination buffer, or nil for owned byte planes.
    ///
    /// - Returns: A frame owning the processed BGRA pixels.
    ///
    /// - Throws: An error if dimensions or buffer layout are invalid or pixel processing fails.
    private static func convertBGRA(
        _ pixelBuffer: CVPixelBuffer,
        outputWidth: Int,
        outputHeight: Int,
        timestampUs: Int64,
        outputPixelBuffer: CVPixelBuffer?
    ) throws -> VideoFrame {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let (sourceRowBytes, sourceOverflow) = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, outputWidth > 0, outputHeight > 0,
            outputWidth.isMultiple(of: 2), outputHeight.isMultiple(of: 2),
            !sourceOverflow,
            CVPixelBufferGetBytesPerRow(pixelBuffer) >= sourceRowBytes,
            CVPixelBufferLockBaseAddress(
                pixelBuffer,
                .readOnly
            ) == kCVReturnSuccess
        else {
            throw mediaError("Invalid BGRA video dimensions or buffer layout")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(
                pixelBuffer,
                .readOnly
            )
        }

        guard let source = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw mediaError("BGRA video pixels are unavailable")
        }

        let crop = centerCrop(
            sourceWidth: width,
            sourceHeight: height,
            targetWidth: outputWidth,
            targetHeight: outputHeight
        )
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let start = source.advanced(by: crop.y * stride + crop.x * 4)
        let format = try VideoFormat(width: outputWidth, height: outputHeight, pixelFormat: .bgra)
        return try renderFrame(
            format: format,
            timestampUs: timestampUs,
            outputPixelBuffer: outputPixelBuffer
        ) { destination, _ in
            try scale(
                source: vImage_Buffer(
                    data: start,
                    height: vImagePixelCount(crop.height),
                    width: vImagePixelCount(crop.width),
                    rowBytes: stride
                ),
                destination: destination,
                bytesPerPixel: 4
            )
        }
    }

    /// Writes pixels into a native buffer or tightly packed byte planes.
    private static func renderFrame(
        format: VideoFormat,
        timestampUs: Int64,
        outputPixelBuffer: CVPixelBuffer?,
        render: (vImage_Buffer, vImage_Buffer?) throws -> Void
    ) throws -> VideoFrame {
        let isNV12 = format.pixelFormat == .nv12
        let width = format.width
        let height = format.height
        let (rowBytes, strideOverflow) = width.multipliedReportingOverflow(by: isNV12 ? 1 : 4)
        guard !strideOverflow else { throw mediaError("Video row size exceeds the supported range") }

        if let outputPixelBuffer {
            let pixelFormat = isNV12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
            guard CVPixelBufferGetWidth(outputPixelBuffer) == width,
                CVPixelBufferGetHeight(outputPixelBuffer) == height,
                CVPixelBufferGetPixelFormatType(outputPixelBuffer) == pixelFormat,
                CVPixelBufferLockBaseAddress(outputPixelBuffer, []) == kCVReturnSuccess
            else {
                throw mediaError("Invalid video destination buffer")
            }
            defer { CVPixelBufferUnlockBaseAddress(outputPixelBuffer, []) }

            if isNV12 {
                guard CVPixelBufferGetPlaneCount(outputPixelBuffer) == 2,
                    CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0) >= rowBytes,
                    CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1) >= rowBytes,
                    let luma = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0),
                    let chroma = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1)
                else {
                    throw mediaError("Invalid NV12 destination planes")
                }
                try render(
                    vImage_Buffer(
                        data: luma,
                        height: vImagePixelCount(height),
                        width: vImagePixelCount(width),
                        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0)
                    ),
                    vImage_Buffer(
                        data: chroma,
                        height: vImagePixelCount(height / 2),
                        width: vImagePixelCount(width / 2),
                        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1)
                    )
                )
            } else {
                let stride = CVPixelBufferGetBytesPerRow(outputPixelBuffer)
                guard stride >= rowBytes, let base = CVPixelBufferGetBaseAddress(outputPixelBuffer) else {
                    throw mediaError("Invalid BGRA destination plane")
                }
                try render(
                    vImage_Buffer(
                        data: base,
                        height: vImagePixelCount(height),
                        width: vImagePixelCount(width),
                        rowBytes: stride
                    ),
                    nil
                )
            }
            return try VideoFrame(format: format, timestampUs: timestampUs, pixelBuffer: outputPixelBuffer)
        }

        let (firstPlaneLength, planeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        let secondPlaneLength = isNV12 ? firstPlaneLength / 2 : 0
        let (byteCount, sizeOverflow) = firstPlaneLength.addingReportingOverflow(secondPlaneLength)
        guard !planeOverflow, !sizeOverflow else { throw mediaError("Video frame size exceeds the supported range") }

        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw mediaError("Failed to allocate video data") }
            let first = vImage_Buffer(
                data: base,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: rowBytes
            )
            let second = isNV12 ? vImage_Buffer(
                data: base.advanced(by: firstPlaneLength),
                height: vImagePixelCount(height / 2),
                width: vImagePixelCount(width / 2),
                rowBytes: rowBytes
            ) : nil
            try render(first, second)
        }

        var planes = [try VideoFramePlane(data: data, stride: rowBytes, byteLength: firstPlaneLength)]
        if isNV12 {
            planes.append(try VideoFramePlane(
                data: data,
                stride: rowBytes,
                byteOffset: firstPlaneLength,
                byteLength: secondPlaneLength
            ))
        }
        return try VideoFrame(format: format, timestampUs: timestampUs, planes: planes)
    }

    /// Copies matching rows directly and resamples only when the dimensions differ.
    private static func scale(
        source: vImage_Buffer,
        destination: vImage_Buffer,
        bytesPerPixel: Int
    ) throws {
        if source.width == destination.width, source.height == destination.height {
            let rowBytes = Int(source.width) * bytesPerPixel
            for row in 0..<Int(source.height) {
                memcpy(
                    destination.data.advanced(by: row * destination.rowBytes),
                    source.data.advanced(by: row * source.rowBytes),
                    rowBytes
                )
            }
            return
        }

        var source = source
        var destination = destination
        let flags = vImage_Flags(kvImageHighQualityResampling)
        let status: vImage_Error
        switch bytesPerPixel {
        case 1:
            status = vImageScale_Planar8(&source, &destination, nil, flags)
        case 2:
            status = vImageScale_CbCr8(&source, &destination, nil, flags)
        default:
            status = vImageScale_ARGB8888(&source, &destination, nil, flags)
        }
        guard status == kvImageNoError else { throw mediaError("Failed to scale video pixels") }
    }

    /// Resolves a centered crop matching the target aspect ratio.
    ///
    /// - Parameters:
    ///   - sourceWidth: The source width.
    ///   - sourceHeight: The source height.
    ///   - targetWidth: The target width.
    ///   - targetHeight: The target height.
    ///
    /// - Returns: A crop rectangle with even-aligned origin and dimensions for NV12.
    private static func centerCrop(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> (x: Int, y: Int, width: Int, height: Int) {
        let sourceAspectRatio = Double(sourceWidth) / Double(sourceHeight)
        let targetAspectRatio = Double(targetWidth) / Double(targetHeight)
        var cropWidth = sourceWidth
        var cropHeight = sourceHeight

        if sourceAspectRatio > targetAspectRatio {
            cropWidth = evenFloor(
                Double(sourceHeight) * targetAspectRatio
            )
        } else if sourceAspectRatio < targetAspectRatio {
            cropHeight = evenFloor(
                Double(sourceWidth) / targetAspectRatio
            )
        }

        return (
            x: evenOffset(Double(sourceWidth - cropWidth) / 2),
            y: evenOffset(Double(sourceHeight - cropHeight) / 2),
            width: cropWidth,
            height: cropHeight
        )
    }

    /// Rounds down to an even dimension of at least two pixels.
    ///
    /// - Parameter value: The dimension to align.
    ///
    /// - Returns: An even dimension of at least 2.
    private static func evenFloor(
        _ value: Double
    ) -> Int {
        max(
            Int(floor(value)) / 2 * 2,
            2
        )
    }

    /// Rounds down to a nonnegative, even offset.
    ///
    /// - Parameter value: The offset to align.
    ///
    /// - Returns: A nonnegative, even offset.
    private static func evenOffset(
        _ value: Double
    ) -> Int {
        max(
            Int(floor(value)) / 2 * 2,
            0
        )
    }

    /// Creates a video conversion error.
    ///
    /// - Parameter message: The error description.
    ///
    /// - Returns: A media error with the specified description.
    private static func mediaError(
        _ message: String
    ) -> XmaxError {
        XmaxError(
            code: .mediaError,
            message: message
        )
    }
}

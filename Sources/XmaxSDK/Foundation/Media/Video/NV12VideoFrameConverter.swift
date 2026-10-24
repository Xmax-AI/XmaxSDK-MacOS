//
//  NV12VideoFrameConverter.swift
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

/// Crops, scales, and rotates system NV12 pixel buffers into contiguous frame data at target display dimensions.
enum NV12VideoFrameConverter {

    /// Center-crops, scales, and rotates an NV12 buffer to the specified display dimensions.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The source NV12 pixel buffer.
    ///   - outputWidth: The output width in pixels; must be positive and even.
    ///   - outputHeight: The output height in pixels; must be positive and even.
    ///   - rotation: The display rotation applied after scaling.
    ///   - timestampUs: The output frame timestamp in microseconds.
    ///
    /// - Returns: An NV12 frame with rotation applied to pixels and a zero rotation flag.
    ///
    /// - Throws: An error on invalid pixel format, plane layout, or dimensions, or buffer conversion failure.
    static func convert(
        pixelBuffer: CVPixelBuffer,
        outputWidth: Int,
        outputHeight: Int,
        rotation: VideoRotation,
        timestampUs: Int64
    ) throws -> VideoFrame {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isNV12 =
            pixelFormat
            == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isNV12,
            CVPixelBufferGetPlaneCount(pixelBuffer) == 2
        else {
            throw mediaError("Video decoder returned a non-NV12 frame")
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
            throw mediaError("Decoded NV12 video dimensions are invalid")
        }

        let lockStatus = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard lockStatus == kCVReturnSuccess else {
            throw mediaError("Failed to lock decoded NV12 video data")
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
            throw mediaError("Decoded NV12 video plane layout is invalid")
        }

        let scaledDimensions = scaledDimensions(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            rotation: rotation
        )
        let crop = centerCrop(
            sourceWidth: width,
            sourceHeight: height,
            targetWidth: scaledDimensions.width,
            targetHeight: scaledDimensions.height
        )
        let scaledData = try scale(
            lumaBaseAddress: lumaBaseAddress,
            lumaStride: lumaStride,
            chromaBaseAddress: chromaBaseAddress,
            chromaStride: chromaStride,
            crop: crop,
            outputWidth: scaledDimensions.width,
            outputHeight: scaledDimensions.height
        )
        let data = try rotate(
            scaledData,
            sourceWidth: scaledDimensions.width,
            sourceHeight: scaledDimensions.height,
            rotation: rotation
        )
        let lumaLength = outputWidth * outputHeight

        return try VideoFrame(
            format: VideoFormat(
                width: outputWidth,
                height: outputHeight,
                pixelFormat: .nv12
            ),
            timestampUs: timestampUs,
            planes: [
                VideoFramePlane(
                    data: data,
                    stride: outputWidth,
                    byteLength: lumaLength
                ),
                VideoFramePlane(
                    data: data,
                    stride: outputWidth,
                    byteOffset: lumaLength,
                    byteLength: lumaLength / 2
                )
            ],
            rotation: .rotation0
        )
    }

    /// Crops and scales NV12 luma and chroma planes.
    ///
    /// - Parameters:
    ///   - lumaBaseAddress: The source luma plane base address.
    ///   - lumaStride: The source luma plane byte count per row.
    ///   - chromaBaseAddress: The source chroma plane base address.
    ///   - chromaStride: The source chroma plane byte count per row.
    ///   - crop: The even-aligned crop rectangle in the source image.
    ///   - outputWidth: The scaled width in pixels.
    ///   - outputHeight: The scaled height in pixels.
    ///
    /// - Returns: NV12 data with contiguous luma and chroma planes.
    ///
    /// - Throws: An error on memory allocation or plane scaling failure.
    private static func scale(
        lumaBaseAddress: UnsafeMutableRawPointer,
        lumaStride: Int,
        chromaBaseAddress: UnsafeMutableRawPointer,
        chromaStride: Int,
        crop: (x: Int, y: Int, width: Int, height: Int),
        outputWidth: Int,
        outputHeight: Int
    ) throws -> Data {
        let lumaLength = outputWidth * outputHeight
        var data = Data(count: lumaLength + lumaLength / 2)
        try data.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else {
                throw mediaError("Failed to allocate decoded NV12 video data")
            }

            if crop.width == outputWidth, crop.height == outputHeight {
                let luma = lumaBaseAddress.advanced(by: crop.y * lumaStride + crop.x)
                let chroma = chromaBaseAddress.advanced(by: crop.y / 2 * chromaStride + crop.x)
                for row in 0..<outputHeight {
                    memcpy(
                        destination.advanced(by: row * outputWidth),
                        luma.advanced(by: row * lumaStride),
                        outputWidth
                    )
                }
                for row in 0..<(outputHeight / 2) {
                    memcpy(
                        destination.advanced(by: lumaLength + row * outputWidth),
                        chroma.advanced(by: row * chromaStride),
                        outputWidth
                    )
                }
                return
            }

            var sourceLuma = vImage_Buffer(
                data: lumaBaseAddress.advanced(
                    by: crop.y * lumaStride + crop.x
                ),
                height: vImagePixelCount(crop.height),
                width: vImagePixelCount(crop.width),
                rowBytes: lumaStride
            )
            var targetLuma = vImage_Buffer(
                data: destination,
                height: vImagePixelCount(outputHeight),
                width: vImagePixelCount(outputWidth),
                rowBytes: outputWidth
            )
            let flags = vImage_Flags(kvImageHighQualityResampling)
            guard
                vImageScale_Planar8(
                    &sourceLuma,
                    &targetLuma,
                    nil,
                    flags
                ) == kvImageNoError
            else {
                throw mediaError("Failed to scale decoded NV12 luma data")
            }

            var sourceChroma = vImage_Buffer(
                data: chromaBaseAddress.advanced(
                    by: crop.y / 2 * chromaStride + crop.x
                ),
                height: vImagePixelCount(crop.height / 2),
                width: vImagePixelCount(crop.width / 2),
                rowBytes: chromaStride
            )
            var targetChroma = vImage_Buffer(
                data: destination.advanced(by: lumaLength),
                height: vImagePixelCount(outputHeight / 2),
                width: vImagePixelCount(outputWidth / 2),
                rowBytes: outputWidth
            )
            guard
                vImageScale_CbCr8(
                    &sourceChroma,
                    &targetChroma,
                    nil,
                    flags
                ) == kvImageNoError
            else {
                throw mediaError("Failed to scale decoded NV12 chroma data")
            }
        }
        return data
    }

    /// Rotates contiguous NV12 pixel data.
    ///
    /// - Parameters:
    ///   - data: The source NV12 data.
    ///   - sourceWidth: The source image width in pixels.
    ///   - sourceHeight: The source image height in pixels.
    ///   - rotation: The rotation angle to apply.
    ///
    /// - Returns: NV12 data rotated by the specified angle; returns the original data for zero rotation.
    ///
    /// - Throws: An error on output buffer allocation or plane rotation failure.
    private static func rotate(
        _ data: Data,
        sourceWidth: Int,
        sourceHeight: Int,
        rotation: VideoRotation
    ) throws -> Data {
        guard rotation != .rotation0 else {
            return data
        }

        let swapsDimensions =
            rotation == .rotation90
            || rotation == .rotation270
        let outputWidth = swapsDimensions ? sourceHeight : sourceWidth
        let outputHeight = swapsDimensions ? sourceWidth : sourceHeight
        let sourceLumaLength = sourceWidth * sourceHeight
        let outputLumaLength = outputWidth * outputHeight
        var output = Data(count: outputLumaLength + outputLumaLength / 2)

        try data.withUnsafeBytes { sourceBytes in
            try output.withUnsafeMutableBytes { outputBytes in
                guard let source = sourceBytes.baseAddress,
                    let destination = outputBytes.baseAddress
                else {
                    throw mediaError(
                        "Failed to allocate rotated NV12 video data"
                    )
                }

                let rotationConstant = rotationConstant(for: rotation)
                var sourceLuma = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source),
                    height: vImagePixelCount(sourceHeight),
                    width: vImagePixelCount(sourceWidth),
                    rowBytes: sourceWidth
                )
                var targetLuma = vImage_Buffer(
                    data: destination,
                    height: vImagePixelCount(outputHeight),
                    width: vImagePixelCount(outputWidth),
                    rowBytes: outputWidth
                )
                guard
                    vImageRotate90_Planar8(
                        &sourceLuma,
                        &targetLuma,
                        rotationConstant,
                        0,
                        vImage_Flags(kvImageNoFlags)
                    ) == kvImageNoError
                else {
                    throw mediaError("Failed to rotate decoded NV12 luma data")
                }

                var sourceChroma = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source).advanced(
                        by: sourceLumaLength
                    ),
                    height: vImagePixelCount(sourceHeight / 2),
                    width: vImagePixelCount(sourceWidth / 2),
                    rowBytes: sourceWidth
                )
                var targetChroma = vImage_Buffer(
                    data: destination.advanced(by: outputLumaLength),
                    height: vImagePixelCount(outputHeight / 2),
                    width: vImagePixelCount(outputWidth / 2),
                    rowBytes: outputWidth
                )
                guard
                    vImageRotate90_Planar16U(
                        &sourceChroma,
                        &targetChroma,
                        rotationConstant,
                        0,
                        vImage_Flags(kvImageNoFlags)
                    ) == kvImageNoError
                else {
                    throw mediaError(
                        "Failed to rotate decoded NV12 chroma data"
                    )
                }
            }
        }
        return output
    }

    /// Calculates scaling dimensions before rotation.
    ///
    /// - Parameters:
    ///   - outputWidth: The final display width.
    ///   - outputHeight: The final display height.
    ///   - rotation: The rotation angle applied after scaling.
    ///
    /// - Returns: The required width and height before rotation.
    private static func scaledDimensions(
        outputWidth: Int,
        outputHeight: Int,
        rotation: VideoRotation
    ) -> (width: Int, height: Int) {
        switch rotation {
        case .rotation90, .rotation270:
            (outputHeight, outputWidth)
        case .rotation0, .rotation180:
            (outputWidth, outputHeight)
        }
    }

    /// Converts display rotation to the vImage quarter-turn count.
    ///
    /// - Parameter rotation: The video display rotation.
    ///
    /// - Returns: The vImage rotation constant.
    private static func rotationConstant(
        for rotation: VideoRotation
    ) -> UInt8 {
        switch rotation {
        case .rotation0:
            0
        case .rotation90:
            3
        case .rotation180:
            2
        case .rotation270:
            1
        }
    }

    /// Calculates a centered crop matching the target aspect ratio.
    ///
    /// - Parameters:
    ///   - sourceWidth: The source image width.
    ///   - sourceHeight: The source image height.
    ///   - targetWidth: The target image width.
    ///   - targetHeight: The target image height.
    ///
    /// - Returns: A crop rectangle with even-aligned position and dimensions for NV12.
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

    /// Rounds a dimension down to an even value of at least two pixels.
    ///
    /// - Parameter value: The dimension to align.
    ///
    /// - Returns: An even dimension of at least 2.
    private static func evenFloor(
        _ value: Double
    ) -> Int {
        max(Int(floor(value)) / 2 * 2, 2)
    }

    /// Rounds an offset down to a nonnegative even value.
    ///
    /// - Parameter value: The offset to align.
    ///
    /// - Returns: A nonnegative even offset.
    private static func evenOffset(
        _ value: Double
    ) -> Int {
        max(Int(floor(value)) / 2 * 2, 0)
    }

    /// Creates a video frame conversion error.
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

//
//  VideoBeautyColorConverter.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

/// Converts SDR frames to the beauty worker's BT.709 input on its serial worker queue.
final class VideoBeautyColorConverter {

    /// The reusable system color conversion session, created only for incompatible SDR color tags.
    private var session: VTPixelTransferSession?

    /// The IOSurface-backed pool used only for converted input frames.
    private var pool: CVPixelBufferPool?

    /// The dimensions of the conversion pool.
    private var dimensions = CGSize.zero

    /// Releases a conversion session if the owner omits explicit cleanup.
    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    /// Preserves compatible buffers or converts their SDR colors without changing frame timing or input pixels.
    ///
    /// - Parameter frame: The post-interpolation result frame, with its source color attachments.
    ///
    /// - Returns: The original frame or an owned, video-range BT.709 NV12 frame of the same dimensions.
    ///
    /// - Throws: A media error for unsupported transfer functions or failed system conversion.
    func prepare(
        _ frame: RealtimeVideoFrame
    ) throws -> RealtimeVideoFrame {
        let input = frame.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(input)
        guard [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].contains(format),
            CVPixelBufferGetWidth(input).isMultiple(of: 2),
            CVPixelBufferGetHeight(input).isMultiple(of: 2)
        else {
            throw Self.error("Beauty requires even-sized NV12 or BGRA frames")
        }
        let transfer = CVBufferCopyAttachment(input, kCVImageBufferTransferFunctionKey, nil) as? String
        let sdrTransfers = [
            kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferTransferFunction_ITU_R_2020,
            kCVImageBufferTransferFunction_sRGB,
            kCVImageBufferTransferFunction_SMPTE_240M_1995,
            kCVImageBufferTransferFunction_Linear,
            kCVImageBufferTransferFunction_UseGamma,
            kCVImageBufferTransferFunction_SMPTE_ST_428_1
        ] as [String]
        if let transfer, !sdrTransfers.contains(transfer) {
            throw Self.error("Result beauty requires SDR video; unsupported transfer function: \(transfer)")
        }

        let colors = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        ]
        guard colors.contains(where: { key, expected in
            guard let actual = CVBufferCopyAttachment(input, key, nil) as? String else { return false }
            return actual != expected as String
        }) else { return frame }

        let session = try conversionSession()
        let output = try makeOutputBuffer(input: input)
        let status = VTPixelTransferSessionTransferImage(
            session,
            from: input,
            to: output
        )
        guard status == noErr else {
            let sourceColors = colors.map { key, _ in
                "\(key)=\(CVBufferCopyAttachment(input, key, nil) as? String ?? "unspecified")"
            }.joined(separator: ", ")
            throw Self.error("Unable to convert result beauty input to BT.709 (\(status)): \(sourceColors)")
        }
        return RealtimeVideoFrame(
            pixelBuffer: output,
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration
        )
    }

    /// Releases system conversion and pool resources on the beauty worker queue.
    func close() {
        if let session { VTPixelTransferSessionInvalidate(session) }
        session = nil
        pool = nil
        dimensions = .zero
    }

    /// Creates a reusable converter with explicit destination color properties.
    ///
    /// - Returns: The configured system pixel transfer session.
    ///
    /// - Throws: A media error if creation or destination color configuration fails.
    private func conversionSession() throws -> VTPixelTransferSession {
        if let session { return session }
        var created: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: nil,
            pixelTransferSessionOut: &created
        )
        guard status == noErr, let created else {
            throw Self.error("Unable to create result beauty color conversion (\(status))")
        }
        for (key, value) in [
            (kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        ] {
            let result = VTSessionSetProperty(
                created,
                key: key,
                value: value
            )
            guard result == noErr else {
                VTPixelTransferSessionInvalidate(created)
                throw Self.error("Unable to configure result beauty color conversion (\(result))")
            }
        }
        session = created
        return created
    }

    /// Allocates a bounded video-range NV12 surface matching the source dimensions.
    ///
    /// - Parameter input: The input defining conversion dimensions.
    ///
    /// - Returns: An owned pixel buffer safe for cross-process beauty processing.
    ///
    /// - Throws: A media error or temporary output pressure when allocation fails.
    private func makeOutputBuffer(
        input: CVPixelBuffer
    ) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let size = CGSize(
            width: width,
            height: height
        )
        if pool == nil || dimensions != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                nil,
                nil,
                attributes as CFDictionary,
                &created
            )
            guard status == kCVReturnSuccess, let created else {
                throw Self.error("Unable to allocate result beauty color pool (\(status))")
            }
            pool = created
            dimensions = size
            let sourceColors = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                kCVImageBufferYCbCrMatrixKey].map { key in
                    "\(key)=\(CVBufferCopyAttachment(input, key, nil) as? String ?? "unspecified")"
                }.joined(separator: ", ")
            XmaxLogger.render.info(message: "Result beauty input color conversion to BT.709: \(sourceColors)")
        }
        guard let pool else { throw Self.error("Result beauty color pool is unavailable") }
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            nil,
            pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary,
            &output
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            throw VideoBeautyProcessingError.outputBackpressure
        }
        guard status == kCVReturnSuccess, let output else {
            throw Self.error("Unable to allocate result beauty color surface (\(status))")
        }
        return output
    }

    /// Creates a recoverable color conversion failure.
    private static func error(
        _ message: String
    ) -> XmaxError {
        XmaxError(
            code: .mediaError,
            message: message
        )
    }
}

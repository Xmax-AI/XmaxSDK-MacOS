//
//  BeautyColorConverter.swift
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

/// Prepares shared SDR result colors and beauty input as BT.709 on a serial owner.
final class BeautyColorConverter {

    /// The maximum number of converted surfaces retained by downstream consumers.
    private let bufferLimit: Int

    /// The SDR transfer functions supported by the result preparation step.
    private static let sdrTransfers = [
        kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVImageBufferTransferFunction_ITU_R_2020,
        kCVImageBufferTransferFunction_sRGB,
        kCVImageBufferTransferFunction_SMPTE_240M_1995,
        kCVImageBufferTransferFunction_Linear,
        kCVImageBufferTransferFunction_UseGamma,
        kCVImageBufferTransferFunction_SMPTE_ST_428_1
    ] as [String]

    /// The reusable system color conversion session, created only for incompatible SDR color tags.
    private var session: VTPixelTransferSession?

    /// The IOSurface-backed pool used only for converted result frames.
    private var pool: CVPixelBufferPool?

    /// The dimensions of the conversion pool.
    private var dimensions = CGSize.zero

    /// Creates a bounded converter for either output delivery or short-lived worker input.
    init(
        bufferLimit: Int = 3
    ) {
        self.bufferLimit = max(1, bufferLimit)
    }

    /// Releases a conversion session if the owner omits explicit cleanup.
    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    /// Prepares SDR output and records unsupported colors for beauty.
    func prepareOutput(
        _ frame: RealtimeVideoFrame
    ) throws -> BeautyFrameInput {
        let input = frame.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(input)
        guard [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].contains(format),
            CVPixelBufferGetWidth(input).isMultiple(of: 2),
            CVPixelBufferGetHeight(input).isMultiple(of: 2)
        else {
            return .unsupported(
                frame,
                Self.error("Beauty requires even-sized NV12 or BGRA frames")
            )
        }
        let transfer = CVBufferCopyAttachment(input, kCVImageBufferTransferFunctionKey, nil) as? String
        if let transfer, !Self.sdrTransfers.contains(transfer) {
            return .unsupported(
                frame,
                Self.error("Result beauty requires SDR video; unsupported transfer function: \(transfer)")
            )
        }

        let colors = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        ]
        guard colors.contains(where: { key, expected in
            let actual = key == kCVImageBufferTransferFunctionKey
                ? transfer
                : CVBufferCopyAttachment(input, key, nil) as? String
            guard let actual else { return false }
            return actual != expected as String
        }) else { return .prepared(frame) }

        let session = try conversionSession()
        let output = try makeOutputBuffer(input: input)
        CVBufferRemoveAllAttachments(output)
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
        return .prepared(
            RealtimeVideoFrame(
                pixelBuffer: output,
                presentationTimeStamp: frame.presentationTimeStamp,
                duration: frame.duration
            )
        )
    }

    /// Prepares standalone beauty input and rejects unsupported colors.
    func prepare(
        _ frame: RealtimeVideoFrame
    ) throws -> RealtimeVideoFrame {
        let input = try prepareOutput(frame)
        if case .unsupported(_, let error) = input { throw error }
        return input.frame
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
            [kCVPixelBufferPoolAllocationThresholdKey: bufferLimit] as CFDictionary,
            &output
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            throw BeautyProcessingError.outputBackpressure
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

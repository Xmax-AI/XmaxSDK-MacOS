//
//  RtcRemoteVideoSink.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import AgoraRtcKit

/// Copies Agora decoded frames into owned buffers for asynchronous rendering and interpolation.
final class RtcRemoteVideoSink: NSObject, AgoraVideoFrameDelegate, @unchecked Sendable {

    /// The handler receiving a numeric UID, channel, and SDK-owned buffer.
    private let frameListener: @Sendable (UInt, String, RealtimeVideoFrame) -> Void

    /// The lock protecting the remote pixel buffer pool.
    private let lock = NSLock()

    /// The reusable remote frame buffer pool.
    private var pool: CVPixelBufferPool?

    /// The current pool dimensions, in pixels.
    private var dimensions = CGSize.zero

    /// The current pool pixel format.
    private var pixelFormat: OSType = 0

    /// Creates a remote decoded frame receiver.
    init(
        frameListener: @escaping @Sendable (UInt, String, RealtimeVideoFrame) -> Void
    ) {
        self.frameListener = frameListener
    }

    /// Requests NV12 pixel buffers for remote frames.
    ///
    /// - Returns: The NV12 video frame format.
    func getVideoFormatPreference() -> AgoraVideoFormat { .cvPixelNV12 }

    /// Requests decoded frames before RTC rendering.
    ///
    /// - Returns: The pre-render frame observation position.
    func getObservedFramePosition() -> AgoraVideoFramePosition { .preRenderer }

    /// Configures callbacks to read original RTC frames only.
    ///
    /// - Returns: Read-only processing mode.
    func getVideoFrameProcessMode() -> AgoraVideoFrameProcessMode { .readOnly }

    /// Requests RTC to apply rotation to pixels before callbacks.
    ///
    /// - Returns: Always returns `true`.
    func getRotationApplied() -> Bool { true }

    /// Requests decoded pixels without an additional RTC rendering mirror transform.
    ///
    /// - Returns: Always returns `false`.
    func getMirrorApplied() -> Bool { false }

    /// Copies decoded buffers and delivers remote frames safe for asynchronous retention.
    ///
    /// - Parameters:
    ///   - frame: The decoded frame supplied by Agora.
    ///   - uid: The remote user's numeric identifier.
    ///   - channelId: The frame's channel identifier.
    ///
    /// - Returns: Always returns `true` so RTC can continue processing the frame.
    func onRenderVideoFrame(
        _ frame: AgoraOutputVideoFrame,
        uid: UInt,
        channelId: String
    ) -> Bool {
        guard let source = frame.pixelBuffer,
            let buffer = lock.withLock({
                copy(
                    source,
                    colorSpace: frame.colorSpace
                )
            })
        else { return true }

        frameListener(
            uid,
            channelId,
            RealtimeVideoFrame(
                pixelBuffer: buffer,
                presentationTimeStamp: CMTime(
                    value: frame.renderTimeMs,
                    timescale: 1000
                )
            )
        )
        return true
    }

    /// Copies biplanar pixels and resolves their color attachments into an owned buffer.
    ///
    /// - Parameters:
    ///   - source: The source pixel buffer, whose pixel format defines full or video range.
    ///   - colorSpace: The RTC color information used when buffer attachments are missing.
    ///
    /// - Returns: An independently retained copy, or `nil` for unsupported layout or allocation failure.
    private func copy(
        _ source: CVPixelBuffer,
        colorSpace: AgoraColorSpace?
    ) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let size = CGSize(
            width: width,
            height: height
        )
        let format = CVPixelBufferGetPixelFormatType(source)
        guard CVPixelBufferGetPlaneCount(source) == 2 else { return nil }
        if pool == nil || dimensions != size || pixelFormat != format {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            guard
                CVPixelBufferPoolCreate(
                    nil,
                    nil,
                    attributes as CFDictionary,
                    &pool
                ) == kCVReturnSuccess
            else {
                return nil
            }
            dimensions = size
            pixelFormat = format
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        guard
            CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &output
            ) == kCVReturnSuccess,
            let output
        else { return nil }

        CVPixelBufferLockBaseAddress(
            source,
            .readOnly
        )
        CVPixelBufferLockBaseAddress(
            output,
            []
        )
        defer {
            CVPixelBufferUnlockBaseAddress(
                output,
                []
            )
            CVPixelBufferUnlockBaseAddress(
                source,
                .readOnly
            )
        }
        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard
                let src = CVPixelBufferGetBaseAddressOfPlane(
                    source,
                    plane
                ),
                let dst = CVPixelBufferGetBaseAddressOfPlane(
                    output,
                    plane
                )
            else { return nil }
            let srcStride = CVPixelBufferGetBytesPerRowOfPlane(
                source,
                plane
            )
            let dstStride = CVPixelBufferGetBytesPerRowOfPlane(
                output,
                plane
            )
            let bytes = min(srcStride, dstStride)
            for row
                in 0..<CVPixelBufferGetHeightOfPlane(
                    source,
                    plane
                )
            {
                memcpy(
                    dst.advanced(by: row * dstStride),
                    src.advanced(by: row * srcStride),
                    bytes
                )
            }
        }
        // Pooled buffers may still carry color attachments from an earlier decoded frame.
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(
            source,
            output
        )
        applyColorSpace(
            colorSpace,
            to: output
        )
        return output
    }

    /// Fills missing color tags from RTC metadata, using Agora's BT.709 default when unspecified.
    ///
    /// - Parameters:
    ///   - colorSpace: The color information accompanying the decoded RTC frame.
    ///   - buffer: The owned buffer, retaining existing color tags and its full/video-range pixel format.
    private func applyColorSpace(
        _ colorSpace: AgoraColorSpace?,
        to buffer: CVPixelBuffer
    ) {
        let primaries: CFString?
        switch colorSpace?.primaryID {
        case .IDBT709?, .idUnspecified?, .idInvalid?, nil:
            primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
        case .IDSMPTE170M?:
            primaries = kCVImageBufferColorPrimaries_SMPTE_C
        case .IDBT2020?:
            primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        @unknown default:
            primaries = nil
        }

        let transfer: CFString?
        switch colorSpace?.transferID {
        case .IDBT709?, .IDSMPTE170M?, .idUnspecified?, .idInvalid?, nil:
            transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        case .IDSMPTEST2084?:
            transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .IDARIB_STD_B67?:
            transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        @unknown default:
            transfer = nil
        }

        let matrix: CFString?
        switch colorSpace?.matrixID {
        case .IDBT709?, .idUnspecified?, .idInvalid?, nil:
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .IDSMPTE170M?:
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case .IDBT2020_NCL?:
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .IDRGB?:
            matrix = nil
        @unknown default:
            matrix = nil
        }

        for (key, value) in [
            (kCVImageBufferColorPrimariesKey, primaries),
            (kCVImageBufferTransferFunctionKey, transfer),
            (kCVImageBufferYCbCrMatrixKey, matrix)
        ] {
            if let value, CVBufferCopyAttachment(buffer, key, nil) == nil {
                CVBufferSetAttachment(
                    buffer,
                    key,
                    value,
                    .shouldPropagate
                )
            }
        }
    }
}

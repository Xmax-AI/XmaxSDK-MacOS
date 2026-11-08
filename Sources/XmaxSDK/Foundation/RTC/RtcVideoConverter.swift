//
//  RtcVideoConverter.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import Foundation
@preconcurrency import AgoraRtcKit

/// Converts between neutral video models and Agora types.
enum RtcVideoConverter {

    /// Creates an Agora external frame, reusing contiguous pixels when possible.
    ///
    /// - Parameter frame: The source frame containing pixel planes, dimensions, and timestamp.
    ///
    /// - Throws: An error if dimensions exceed platform limits or plane count or layout is invalid.
    static func convertFrame(
        _ frame: VideoFrame
    ) throws -> AgoraVideoFrame {
        let width = frame.format.width
        let height = frame.format.height
        guard let rtcWidth = Int32(exactly: width),
            let rtcHeight = Int32(exactly: height)
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Video frame dimensions exceed the RTC range"
            )
        }

        let result = AgoraVideoFrame()
        result.time = CMTime(value: frame.timestampUs, timescale: 1000000)
        result.rotation = 0

        switch frame.storage {
        case .pixelBuffer(let pixelBuffer):
            result.format = frame.format.pixelFormat == .nv12
                ? AgoraVideoFormat.cvPixelNV12.rawValue : AgoraVideoFormat.cvPixelBGRA.rawValue
            result.textureBuf = pixelBuffer
        case .planes(let planes):
            result.format = convertPixelFormat(frame.format.pixelFormat)
            result.strideInPixels = rtcWidth
            result.height = rtcHeight
            result.dataBuf = try packedFrameData(planes, format: frame.format)
        }
        return result
    }

    /// Validates plane bounds before sharing or repacking the owned bytes.
    private static func packedFrameData(
        _ planes: [VideoFramePlane],
        format: VideoFormat
    ) throws -> Data {
        let width = format.width
        let height = format.height
        let layout: [(bytes: Int, rows: Int)]
        switch format.pixelFormat {
        case .nv12:
            layout = [(width, height), (((width + 1) / 2) * 2, (height + 1) / 2)]
        case .bgra:
            layout = [(width * 4, height)]
        }
        guard planes.count == layout.count else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Video frame requires \(layout.count) data planes"
            )
        }

        for (plane, size) in zip(
            planes,
            layout
        ) {
            guard plane.stride >= size.bytes,
                size.rows > 0,
                plane.byteLength >= size.bytes,
                size.rows - 1 <= (plane.byteLength - size.bytes) / plane.stride
            else {
                throw XmaxError(
                    code: .invalidConfiguration,
                    message: "Video frame plane is smaller than its dimensions"
                )
            }
        }

        return packedData(from: planes, layout: layout) ?? repack(planes, layout: layout)
    }

    /// Returns shared storage only when it contains exactly the required pixels in order.
    private static func packedData(
        from planes: [VideoFramePlane],
        layout: [(bytes: Int, rows: Int)]
    ) -> Data? {
        let data = planes[0].data
        var offset = 0
        for (plane, size) in zip(
            planes,
            layout
        ) {
            guard plane.stride == size.bytes, plane.byteOffset == offset,
                plane.data.count == data.count
            else { return nil }
            // The validated plane fits in its storage at this stride and offset.
            offset += size.bytes * size.rows
        }
        guard offset == data.count else { return nil }
        let sharesStorage = data.withUnsafeBytes { bytes in
            planes.dropFirst().allSatisfy { plane in
                plane.data.withUnsafeBytes { $0.baseAddress == bytes.baseAddress }
            }
        }
        return sharesStorage ? data : nil
    }

    /// Copies pixels from validated planes into contiguous storage.
    private static func repack(
        _ planes: [VideoFramePlane],
        layout: [(bytes: Int, rows: Int)]
    ) -> Data {
        var data = Data()
        for (plane, size) in zip(
            planes,
            layout
        ) {
            plane.data.withUnsafeBytes { bytes in
                for row in 0..<size.rows {
                    let start = bytes.baseAddress!.advanced(by: plane.byteOffset + row * plane.stride)
                    data.append(
                        start.assumingMemoryBound(to: UInt8.self),
                        count: size.bytes
                    )
                }
            }
        }
        return data
    }

    /// Converts SDK encoding parameters to Agora configuration.
    ///
    /// - Parameter configuration: Dimensions, frame rate, bitrate bounds, and encoding preferences.
    /// - Returns: Agora encoding configuration with upstream mirroring disabled and adaptive orientation.
    static func makeEncoderConfiguration(
        _ configuration: VideoEncodingConfiguration
    ) -> AgoraVideoEncoderConfiguration {
        let result = AgoraVideoEncoderConfiguration(
            size: CGSize(
                width: configuration.width,
                height: configuration.height
            ),
            frameRate: configuration.frameRate,
            bitrate: max(0, configuration.maximumBitrate),
            orientationMode: .adaptative,
            mirrorMode: .disabled
        )
        result.minBitrate = configuration.minimumBitrate
        result.degradationPreference =
            switch configuration.encoderPreference {
            case .auto: .maintainAuto
            case .maintainFramerate: .maintainFramerate
            case .maintainQuality: .maintainQuality
            }
        return result
    }

    /// Maps SDK pixel formats to Agora external frame formats.
    ///
    /// - Parameter format: The SDK video pixel format.
    ///
    /// - Returns: The corresponding Agora pixel format identifier.
    static func convertPixelFormat(
        _ format: VideoPixelFormat
    ) -> Int {
        switch format {
        case .bgra: 2
        case .nv12: 8
        }
    }
}

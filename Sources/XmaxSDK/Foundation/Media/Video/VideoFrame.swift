//
//  VideoFrame.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreVideo

/// A video frame retaining upright pixels and their timestamp.
struct VideoFrame: Equatable, Sendable {

    /// Owns frame pixels. Pixel buffers are read-only after capture publishes the frame.
    enum Storage: Equatable, @unchecked Sendable {

        /// Independently owned byte planes.
        case planes([VideoFramePlane])

        /// A native buffer retained by each consumer until it finishes with the frame.
        case pixelBuffer(CVPixelBuffer)

        /// Compares byte planes by value and native buffers by identity.
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.planes(let lhs), .planes(let rhs)):
                lhs == rhs
            case (.pixelBuffer(let lhs), .pixelBuffer(let rhs)):
                lhs === rhs
            default:
                false
            }
        }
    }

    /// The frame dimensions and pixel format.
    let format: VideoFormat

    /// The timestamp on the shared media timeline, in microseconds.
    let timestampUs: Int64

    /// The image's pixel storage.
    let storage: Storage

    /// Creates a frame with pixel planes and a timestamp.
    ///
    /// - Parameters:
    ///   - format: The video dimensions and pixel format.
    ///   - timestampUs: The frame timestamp in microseconds; must be nonnegative.
    ///   - planes: The pixel planes, containing at least one element.
    ///
    /// - Throws: A configuration error for negative timestamps or empty pixel planes.
    init(
        format: VideoFormat,
        timestampUs: Int64,
        planes: [VideoFramePlane]
    ) throws {
        guard timestampUs >= 0 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Video frame timestamp must be non-negative"
            )
        }
        guard !planes.isEmpty else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Video frame must contain at least one plane"
            )
        }

        self.format = format
        self.timestampUs = timestampUs
        storage = .planes(planes)
    }

    /// Retains an SDK-owned buffer matching the resolved video format.
    init(
        format: VideoFormat,
        timestampUs: Int64,
        pixelBuffer: CVPixelBuffer
    ) throws {
        guard timestampUs >= 0 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Video frame timestamp must be non-negative"
            )
        }

        self.format = format
        self.timestampUs = timestampUs
        storage = .pixelBuffer(pixelBuffer)
    }
}

//
//  VideoFrame.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// A video frame retaining upright pixels and their timestamp.
struct VideoFrame: Equatable, Sendable {

    /// The frame dimensions and pixel format.
    let format: VideoFormat

    /// The timestamp on the shared media timeline, in microseconds.
    let timestampUs: Int64

    /// The image's pixel planes.
    let planes: [VideoFramePlane]

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
        self.planes = planes
    }
}

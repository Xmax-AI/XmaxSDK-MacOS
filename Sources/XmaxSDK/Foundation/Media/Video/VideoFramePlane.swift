//
//  VideoFramePlane.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// A pixel data plane in a video frame.
struct VideoFramePlane: Equatable, Sendable {

    /// The bytes containing this plane.
    let data: Data

    /// The byte stride between pixel rows.
    let stride: Int

    /// The plane's byte offset within the data.
    let byteOffset: Int

    /// The plane's byte count.
    let byteLength: Int

    /// Creates a video pixel plane referencing a valid byte range.
    ///
    /// - Parameters:
    ///   - data: The nonempty data retaining pixel bytes.
    ///   - stride: The row byte stride; must be positive.
    ///   - byteOffset: The plane's starting byte offset in the buffer.
    ///   - byteLength: The valid plane byte count; `nil` uses all data after the offset.
    ///
    /// - Throws: A configuration error for empty data, out-of-bounds ranges, or invalid row stride.
    init(
        data: Data,
        stride: Int,
        byteOffset: Int = 0,
        byteLength: Int? = nil
    ) throws {
        guard !data.isEmpty,
            byteOffset >= 0,
            byteOffset < data.count
        else {
            throw Self.invalidRangeError
        }

        let resolvedByteLength = byteLength ?? data.count - byteOffset
        guard resolvedByteLength > 0,
            resolvedByteLength <= data.count - byteOffset
        else {
            throw Self.invalidRangeError
        }
        guard stride > 0 else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Video frame plane stride must be a positive integer"
            )
        }

        self.data = data
        self.stride = stride
        self.byteOffset = byteOffset
        self.byteLength = resolvedByteLength
    }

    /// The error for an invalid plane byte range.
    private static var invalidRangeError: XmaxError {
        XmaxError(
            code: .invalidConfiguration,
            message: "Video frame plane range is invalid"
        )
    }
}

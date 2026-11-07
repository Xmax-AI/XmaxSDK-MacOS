//
//  EncodingBitratePolicy.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Resolves uplink bitrate bounds and estimates the maximum used by downstream signaling.
enum EncodingBitratePolicy {

    /// Validates the uplink format and resolves its bitrate bounds.
    ///
    /// - Parameter videoFormat: The video format with dimensions, frame rate, and optional bitrate bounds.
    ///
    /// - Returns: The minimum and maximum bitrate in kbps.
    ///
    /// - Throws: An error on invalid format, bitrate overflow, or conflicting bounds.
    static func resolve(
        _ videoFormat: RealtimeVideoFormat
    ) throws -> (minimum: Int, maximum: Int) {
        try videoFormat.validate()
        guard videoFormat.width.isMultiple(of: 4), videoFormat.height.isMultiple(of: 4) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Uplink video width and height must be multiples of 4"
            )
        }

        let maximum = try videoFormat.maximumBitrate ?? estimateMaximum(
            width: videoFormat.width,
            height: videoFormat.height,
            fps: videoFormat.fps
        )
        let minimum = videoFormat.minimumBitrate ?? min(500, maximum)
        guard minimum <= maximum else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Minimum bitrate must not exceed maximum bitrate after applying SDK defaults"
            )
        }

        return (minimum, maximum)
    }

    /// Estimates the maximum bitrate in kbps for validated dimensions and frame rate.
    static func estimateMaximum(
        width: Int,
        height: Int,
        fps: Int
    ) throws -> Int {
        let estimate =
            (resolveMaximumBitrate(
                pixels: Double(width) * Double(height),
                fps: Double(fps)
            ) * 0.6).rounded(.toNearestOrEven)
        guard estimate.isFinite, estimate < Double(Int.max) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Realtime video format exceeds the supported bitrate range"
            )
        }
        return max(100, Int(estimate))
    }
}

/// Reference curves for estimating the maximum bitrate by resolution and frame rate.
/// See https://docs.byteplus.com/id/docs/byteplus-rtc/docs-70122.
private extension EncodingBitratePolicy {

    /// A reference point mapping resolution or frame rate to recommended bitrate.
    typealias BitratePoint = (value: Double, bitrate: Double)

    /// The pixel area and bitrate references at 15 fps, in kbps.
    static let referenceBitratesAt15FPS: [BitratePoint] = [
        (120 * 120, 50),
        (160 * 120, 65),
        (180 * 180, 100),
        (240 * 180, 120),
        (320 * 180, 140),
        (320 * 240, 200),
        (424 * 240, 220),
        (360 * 360, 260),
        (480 * 360, 320),
        (640 * 360, 400),
        (640 * 480, 500),
        (848 * 480, 610),
        (960 * 720, 910),
        (1280 * 720, 1130),
        (1920 * 1080, 2080)
    ]

    /// The pixel area and bitrate references at 30 fps, in kbps.
    static let referenceBitratesAt30FPS: [BitratePoint] = [
        (360 * 360, 400),
        (480 * 360, 490),
        (640 * 360, 600),
        (640 * 480, 750),
        (848 * 480, 930),
        (960 * 720, 1380),
        (1280 * 720, 1710),
        (1920 * 1080, 3150)
    ]

    /// Interpolates reference maximum bitrate by pixel area and frame rate.
    ///
    /// - Parameters:
    ///   - pixels: The total video pixel area.
    ///   - fps: The video frames per second.
    ///
    /// - Returns: The reference maximum bitrate in kbps before the budget multiplier.
    static func resolveMaximumBitrate(
        pixels: Double,
        fps: Double
    ) -> Double {
        let bitrate15 = interpolate(
            pixels,
            points: referenceBitratesAt15FPS
        )
        let bitrate30: Double
        let first30 = referenceBitratesAt30FPS[0]
        if pixels < first30.value {
            // Small dimensions follow the 15fps curve, connecting to the first 30fps reference point.
            let reference15 = interpolate(
                first30.value,
                points: referenceBitratesAt15FPS
            )
            bitrate30 = bitrate15 * (first30.bitrate / reference15)
        } else {
            bitrate30 = interpolate(
                pixels,
                points: referenceBitratesAt30FPS
            )
        }

        // The 10fps curve follows the 15fps shape using 400kbps at 640×480 as its reference.
        let bitrate10 = bitrate15 * (400.0 / 500)
        // The 60fps curve follows the 30fps shape and matches the 1080p maximum bitrate reference.
        let maximum60 = bitrate30 * (6500.0 / 3150)
        return interpolate(
            fps,
            points: [
                (10, bitrate10 * 2), (15, bitrate15 * 2), (30, bitrate30 * 2), (60, maximum60)
            ]
        )
    }

    /// Interpolates linearly between adjacent points and extrapolates using the nearest endpoint ratio.
    ///
    /// - Parameters:
    ///   - value: The pixel area or frame rate to evaluate.
    ///   - points: Nonempty reference points sorted by ascending x coordinate.
    ///
    /// - Returns: The interpolated or extrapolated bitrate.
    static func interpolate(
        _ value: Double,
        points: [BitratePoint]
    ) -> Double {
        let first = points[0]
        if value <= first.value {
            return first.bitrate * (value / first.value)
        }
        for index in 1..<points.count {
            let upper = points[index]
            if value <= upper.value {
                let lower = points[index - 1]
                let ratio = (value - lower.value) / (upper.value - lower.value)
                return lower.bitrate + (upper.bitrate - lower.bitrate) * ratio
            }
        }
        let last = points[points.count - 1]
        return last.bitrate * (value / last.value)
    }
}

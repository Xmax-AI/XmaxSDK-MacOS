//
//  FrameInterpolationSupport.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
#if !targetEnvironment(simulator)
    import VideoToolbox
#endif

/// Checks environment and video format support for low-latency interpolation.
enum FrameInterpolationSupport {

    /// Whether the current platform and hardware support frame interpolation.
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
            false
        #else
            if #available(macOS 26.0, *) {
                VTLowLatencyFrameInterpolationConfiguration.isSupported
            } else {
                false
            }
        #endif
    }

    /// Checks whether the device supports low-latency interpolation at the specified dimensions.
    ///
    /// - Parameter size: The video dimensions in pixels for interpolation.
    ///
    /// - Returns: `true` if the system, device, and dimensions meet interpolation requirements.
    static func supports(
        size: CGSize
    ) -> Bool {
        guard isSupported,
            let width = integralDimension(size.width),
            let height = integralDimension(size.height)
        else {
            return false
        }

        #if targetEnvironment(simulator)
            return false
        #else
            if #available(macOS 26.0, *) {
                return VTLowLatencyFrameInterpolationConfiguration(
                    frameWidth: width,
                    frameHeight: height,
                    numberOfInterpolatedFrames: 1
                ) != nil
            }
            return false
        #endif
    }
}

private extension FrameInterpolationSupport {

    /// Converts a valid positive integral dimension to an integer.
    ///
    /// - Parameter value: The dimension component to convert.
    ///
    /// - Returns: A representable positive integer, or `nil` for invalid dimensions.
    static func integralDimension(
        _ value: CGFloat
    ) -> Int? {
        guard value.isFinite,
            value > 0,
            value <= CGFloat(Int.max)
        else {
            return nil
        }
        let roundedValue = value.rounded()
        guard roundedValue == value else { return nil }
        return Int(roundedValue)
    }
}

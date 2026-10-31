//
//  RealtimeVideoBeautyOptions.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Beauty strengths applied once to generated result frames before preview and public media output.
/// All strengths must be finite values in `0...1`. Camera input and upstream publication are unchanged.
public struct RealtimeVideoBeautyOptions: Equatable, Sendable {

    /// Skin smoothing strength, defaulting to 0.3.
    public var smoothness: Float

    /// Skin lightening strength, defaulting to 0.2.
    public var lightening: Float

    /// Sharpening strength, defaulting to 0.2.
    public var sharpness: Float

    /// Skin redness strength, defaulting to 0.1.
    public var redness: Float

    /// Creates result beauty options. Validation occurs when the options are applied.
    public init(
        smoothness: Float = 0.3,
        lightening: Float = 0.2,
        sharpness: Float = 0.2,
        redness: Float = 0.1
    ) {
        self.smoothness = smoothness
        self.lightening = lightening
        self.sharpness = sharpness
        self.redness = redness
    }

    /// Rejects invalid strengths before modifying an active processor.
    ///
    /// - Throws: `XmaxError` with `invalidConfiguration` for nonfinite or out-of-range values.
    public func validate() throws {
        guard [smoothness, lightening, sharpness, redness].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Beauty strengths must be finite numbers from 0 to 1"
            )
        }
    }
}

/// Reports recoverable result beauty failures on the main actor after original-frame output is restored.
public typealias RealtimeVideoBeautyErrorListener = @MainActor @Sendable (XmaxError) -> Void

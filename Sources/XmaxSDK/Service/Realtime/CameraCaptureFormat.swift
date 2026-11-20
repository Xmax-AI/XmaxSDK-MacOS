//
//  CameraCaptureFormat.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Preferred camera input dimensions before rotation, independent of the shared output format.
public struct CameraCaptureFormat: Equatable, Sendable {

    /// The preferred input width in pixels.
    public let width: Int

    /// The preferred input height in pixels.
    public let height: Int

    /// The preferred input frame rate, or nil to use the target frame rate.
    public let fps: Double?

    /// Creates a preference that the camera resolves to a supported capture format.
    public init(
        width: Int,
        height: Int,
        fps: Double? = nil
    ) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    /// Rejects nonpositive dimensions and nonfinite or nonpositive frame rates.
    func validate() throws {
        guard width > 0, height > 0,
            fps.map({ $0.isFinite && $0 > 0 }) ?? true
        else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Camera capture dimensions must be positive and fps must be finite and positive"
            )
        }
    }
}

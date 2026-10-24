//
//  MediaServicingStub.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import Foundation
@testable import XmaxSDK

final class MediaServicingStub: MediaServicing, @unchecked Sendable {

    /// Test configuration
    let model: RealtimeModel
    private let resolvedSize: CGSize
    private let resolvedGenerationSize: CGSize?
    private let resolutionError: (any Error)?
    private let frameInterpolationSupported: Bool

    /// Concurrent state
    private let lock = NSLock()
    private var storedRequestedSizes: [CGSize] = []

    init(
        resolvedSize: CGSize,
        resolvedGenerationSize: CGSize? = nil,
        model: RealtimeModel = .x2_1_1_preview_cn,
        resolutionError: (any Error)? = nil,
        frameInterpolationSupported: Bool = false
    ) {
        self.resolvedSize = resolvedSize
        self.resolvedGenerationSize = resolvedGenerationSize
        self.model = model
        self.resolutionError = resolutionError
        self.frameInterpolationSupported = frameInterpolationSupported
    }

    var requestedSizes: [CGSize] {
        lock.withLock { storedRequestedSizes }
    }

    func resolveMediaSize(_ size: CGSize, source: RealtimeMediaSource) throws -> CGSize {
        try lock.withLock {
            storedRequestedSizes.append(size)
            if let resolutionError {
                throw resolutionError
            }
            return source == .camera || source == .external
                ? resolvedSize : try MediaService(model: model).resolveMediaSize(size, source: source)
        }
    }

    func resolveGenerationSize(_ size: CGSize) throws -> CGSize {
        if let resolvedGenerationSize { return resolvedGenerationSize }
        return try MediaService(model: model).resolveGenerationSize(size)
    }

    func resolveTargetSize(_ sourceSize: CGSize, maximumSize: CGSize, frameInterpolationEnabled: Bool) throws -> CGSize {
        try MediaService(model: model).resolveTargetSize(
            sourceSize,
            maximumSize: maximumSize,
            frameInterpolationEnabled: frameInterpolationEnabled
        )
    }

    func supportsFrameInterpolation(for size: CGSize) -> Bool {
        frameInterpolationSupported
    }
}

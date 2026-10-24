//
//  RemoteVideoFramePipeline.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Processes remote decoded frames serially, inserting one intermediate frame when available.
actor RemoteVideoFramePipeline {

    /// Checks whether interpolation supports the specified video pixel dimensions.
    typealias FrameInterpolationSupportChecker =
        @Sendable (
            _ size: CGSize
        ) -> Bool

    /// Asynchronously receives final video frames and their output stream generation identifiers.
    typealias OutputListener =
        @Sendable (
            _ frame: RealtimeVideoFrame,
            _ outputToken: UInt64
        ) async -> Void

    /// Creates an interpolator from the source format; nil when unavailable.
    typealias InterpolationManagerFactory =
        @Sendable (
            _ frame: RealtimeVideoFrame
        ) throws -> (any FrameInterpolationManaging)?

    /// The dimension-based interpolation capability check.
    private let frameInterpolationSupportChecker: FrameInterpolationSupportChecker

    /// The frame-based interpolation processor factory.
    private let interpolationManagerFactory: InterpolationManagerFactory

    /// The asynchronous final frame and stream identifier handler.
    private let outputListener: OutputListener

    /// The interpolation failure and fallback handler.
    private let errorListener: XmaxErrorListener

    /// The active remote interpolation processor.
    private var interpolationManager: (any FrameInterpolationManaging)?

    /// The latest unprocessed remote frame.
    private var pendingFrame: RealtimeVideoFrame?

    /// The serial frame consumption task.
    private var drainTask: Task<Void, Never>?

    /// The task releasing previous interpolation resources.
    private var cleanupTask: Task<Void, Never>?

    /// The requested interpolation setting.
    private var interpolationEnabled: Bool

    /// The current processor's video dimensions.
    private var interpolationVideoSize: CGSize?

    /// The preceding output presentation time.
    private var previousPresentationTimeStamp: CMTime?

    /// The processing revision rejecting stale output.
    private var generation = 0

    /// The output stream identifier.
    private var outputToken: UInt64

    /// Creates a remote frame pipeline with stream validity checks.
    ///
    /// - Parameters:
    ///   - interpolationEnabled: Whether interpolation is initially enabled.
    ///   - outputToken: The current output stream generation identifier.
    ///   - frameInterpolationSupportChecker: The operation checking interpolation dimension support.
    ///   - interpolationManagerFactory: The interpolator factory using the input frame.
    ///   - outputListener: The asynchronous callback receiving final frames and stream identifiers.
    ///   - errorListener: The callback receiving interpolation fallback errors.
    init(
        interpolationEnabled: Bool,
        outputToken: UInt64,
        frameInterpolationSupportChecker:
            @escaping FrameInterpolationSupportChecker = {
                FrameInterpolationSupport.supports(size: $0)
            },
        interpolationManagerFactory: @escaping InterpolationManagerFactory = {
            #if targetEnvironment(simulator)
                nil
            #else
                if #available(macOS 26.0, *) {
                    try FrameInterpolationManager(frame: $0)
                } else {
                    nil
                }
            #endif
        },
        outputListener: @escaping OutputListener,
        errorListener: @escaping XmaxErrorListener
    ) {
        self.interpolationEnabled = interpolationEnabled
        self.outputToken = outputToken
        self.frameInterpolationSupportChecker =
            frameInterpolationSupportChecker
        self.interpolationManagerFactory = interpolationManagerFactory
        self.outputListener = outputListener
        self.errorListener = errorListener
    }

    /// Whether interpolation is requested.
    var isFrameInterpolationEnabled: Bool {
        interpolationEnabled
    }

    /// Enqueues a frame for the current output stream.
    ///
    /// - Parameter frame: The latest remote decoded frame.
    func enqueue(
        _ frame: RealtimeVideoFrame
    ) {
        enqueue(
            frame,
            outputToken: outputToken
        )
    }

    /// Accepts the latest valid stream frame and starts processing after cleanup finishes.
    ///
    /// - Parameters:
    ///   - frame: The latest remote decoded frame.
    ///   - outputToken: The frame's output stream identifier.
    func enqueue(
        _ frame: RealtimeVideoFrame,
        outputToken: UInt64
    ) {
        guard outputToken >= self.outputToken else { return }
        if outputToken > self.outputToken {
            resetProcessing(outputToken: outputToken)
        }
        pendingFrame = frame
        guard drainTask == nil else { return }
        let activeGeneration = generation
        let activeOutputToken = outputToken
        drainTask = Task { [weak self, cleanupTask] in
            await cleanupTask?.value
            await self?.drainFrames(
                generation: activeGeneration,
                outputToken: activeOutputToken
            )
        }
    }

    /// Validates and switches interpolation mode, awaiting old processing resource cleanup.
    ///
    /// - Parameters:
    ///   - enabled: Whether to enable interpolation.
    ///   - videoSize: The expected return dimensions; checks only device support when unknown.
    ///   - outputToken: The output stream identifier at call time.
    ///
    /// - Throws: When enabling interpolation on unsupported devices or dimensions.
    func setFrameInterpolationEnabled(
        _ enabled: Bool,
        videoSize: CGSize?,
        outputToken: UInt64
    ) async throws {
        if enabled {
            let supported =
                videoSize.map(frameInterpolationSupportChecker)
                ?? FrameInterpolationSupport.isSupported
            guard supported else {
                throw Self.unsupportedError(videoSize: videoSize)
            }
        }
        interpolationEnabled = enabled
        interpolationVideoSize = enabled ? videoSize : nil
        // Mode changes retain stream identity and cannot overwrite a stream switched during an asynchronous wait.
        resetProcessing(outputToken: max(outputToken, self.outputToken))
        await cleanupTask?.value
    }

    /// Updates output stream validity and waits for old processing resources to clear.
    ///
    /// - Parameter outputToken: The target output stream identifier; old identifiers cannot overwrite the current
    ///   stream.
    func reset(
        outputToken: UInt64
    ) async {
        if outputToken > self.outputToken {
            resetProcessing(outputToken: outputToken)
        }
        await cleanupTask?.value
    }
}

private extension RemoteVideoFramePipeline {

    /// Records the frame format determining interpolator reuse.
    struct FrameSignature: Equatable {

        /// The interpolation input width, in pixels.
        let width: Int

        /// The interpolation input height, in pixels.
        let height: Int

        /// The interpolation input pixel format.
        let pixelFormat: OSType

        /// Extracts frame dimensions and pixel format.
        ///
        /// - Parameter frame: The frame used to check interpolator compatibility.
        init(
            _ frame: RealtimeVideoFrame
        ) {
            width = CVPixelBufferGetWidth(frame.pixelBuffer)
            height = CVPixelBufferGetHeight(frame.pixelBuffer)
            pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        }

        /// The interpolation input dimensions.
        var size: CGSize {
            CGSize(
                width: width,
                height: height
            )
        }
    }

    /// Invalidates in-flight processing and serially releases the old interpolator and tasks.
    ///
    /// - Parameter outputToken: The new output stream generation identifier.
    func resetProcessing(
        outputToken: UInt64
    ) {
        generation += 1
        self.outputToken = outputToken
        drainTask?.cancel()
        let previousDrainTask = drainTask
        let previousCleanupTask = cleanupTask
        let previousManager = interpolationManager
        drainTask = nil
        pendingFrame = nil
        previousPresentationTimeStamp = nil
        interpolationManager = nil
        cleanupTask = Task {
            await previousCleanupTask?.value
            await previousManager?.close()
            await previousDrainTask?.value
        }
    }

    /// Processes the latest pending frame and rejects cancelled or stale results.
    ///
    /// - Parameters:
    ///   - activeGeneration: The current frame processing version.
    ///   - activeOutputToken: The current output stream identifier.
    func drainFrames(
        generation activeGeneration: Int,
        outputToken activeOutputToken: UInt64
    ) async {
        while !Task.isCancelled,
            generation == activeGeneration,
            let frame = pendingFrame
        {
            pendingFrame = nil
            let sourceDuration = frameDuration(
                for: frame.presentationTimeStamp
            )
            let outputFrames = await process(
                frame,
                sourceDuration: sourceDuration,
                generation: activeGeneration
            )
            guard !Task.isCancelled,
                generation == activeGeneration
            else {
                break
            }
            for outputFrame in outputFrames {
                guard !Task.isCancelled,
                    generation == activeGeneration
                else {
                    break
                }
                await outputListener(
                    outputFrame,
                    activeOutputToken
                )
            }
        }
        if generation == activeGeneration {
            drainTask = nil
        }
    }

    /// Interpolates valid frames or passes them through when disabled or falling back.
    ///
    /// - Parameters:
    ///   - frame: The current remote decoded frame.
    ///   - sourceDuration: The source frame display duration.
    ///   - activeGeneration: The current frame processing version.
    ///
    /// - Returns: The output frames, or an empty array if processing is invalidated.
    func process(
        _ frame: RealtimeVideoFrame,
        sourceDuration: CMTime,
        generation activeGeneration: Int
    ) async -> [RealtimeVideoFrame] {
        guard interpolationEnabled else {
            return [
                passthrough(
                    frame,
                    duration: sourceDuration
                )
            ]
        }

        let signature = FrameSignature(frame)
        // During return resizing, old-size frames stay visible without interpolation or disabling the user setting.
        if let interpolationVideoSize, signature.size != interpolationVideoSize {
            let previousManager = interpolationManager
            interpolationManager = nil
            await previousManager?.close()
            return [
                passthrough(
                    frame,
                    duration: sourceDuration
                )
            ]
        }
        guard frameInterpolationSupportChecker(signature.size) else {
            await disableAfterFailure(Self.unsupportedError(videoSize: signature.size))
            return [
                passthrough(
                    frame,
                    duration: sourceDuration
                )
            ]
        }

        do {
            if interpolationManager?.matches(frame) != true {
                let previousManager = interpolationManager
                interpolationManager = nil
                await previousManager?.close()

                guard !Task.isCancelled,
                    generation == activeGeneration
                else {
                    return []
                }
                interpolationManager = try interpolationManagerFactory(frame)
            }
            guard let interpolationManager else {
                throw Self.unsupportedError(videoSize: signature.size)
            }
            return try await interpolationManager.process(
                frame,
                sourceDuration: sourceDuration
            )
        } catch {
            guard !Task.isCancelled,
                generation == activeGeneration
            else {
                return []
            }
            let resolvedError: XmaxError
            if let xmaxError = error as? XmaxError {
                resolvedError = xmaxError
            } else {
                resolvedError = XmaxError(
                    code: .mediaError,
                    message: "Frame interpolation failed: " + (error as NSError).localizedDescription
                )
            }
            await disableAfterFailure(resolvedError)
            return [
                passthrough(
                    frame,
                    duration: sourceDuration
                )
            ]
        }
    }

    /// Disables interpolation, reports the fallback reason, and releases the processor.
    ///
    /// - Parameter error: The error causing interpolation fallback.
    func disableAfterFailure(
        _ error: XmaxError
    ) async {
        interpolationEnabled = false
        let previousManager = interpolationManager
        interpolationManager = nil
        errorListener(error)
        await previousManager?.close()
    }

    /// Preserves source pixels and timestamp while supplying frame duration.
    ///
    /// - Parameters:
    ///   - frame: The video frame to pass through.
    ///   - duration: The output frame display duration.
    ///
    /// - Returns: The source frame with a valid display duration.
    func passthrough(
        _ frame: RealtimeVideoFrame,
        duration: CMTime
    ) -> RealtimeVideoFrame {
        RealtimeVideoFrame(
            pixelBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: duration
        )
    }

    /// Estimates source frame duration from adjacent valid timestamps.
    ///
    /// - Parameter presentationTimeStamp: The current frame presentation timestamp.
    ///
    /// - Returns: The valid frame interval, or 1/24 second if it cannot be estimated.
    func frameDuration(
        for presentationTimeStamp: CMTime
    ) -> CMTime {
        defer {
            if presentationTimeStamp.isValid {
                previousPresentationTimeStamp = presentationTimeStamp
            }
        }
        guard presentationTimeStamp.isValid,
            let previousPresentationTimeStamp,
            previousPresentationTimeStamp.isValid
        else {
            return CMTime(
                value: 1,
                timescale: 24
            )
        }

        let duration = presentationTimeStamp - previousPresentationTimeStamp
        guard duration.isValid,
            duration > .zero,
            duration
                < CMTime(
                    seconds: 1,
                    preferredTimescale: 600
                )
        else {
            return CMTime(
                value: 1,
                timescale: 24
            )
        }
        return duration
    }

    /// Creates an error for unsupported interpolation devices or dimensions.
    ///
    /// - Parameter videoSize: The unsupported video dimensions; `nil` indicates unsupported device capability.
    ///
    /// - Returns: An interpolation error describing the unsupported capability.
    static func unsupportedError(
        videoSize: CGSize?
    ) -> XmaxError {
        let sizeDescription: String
        if let videoSize {
            sizeDescription = " for \(Int(videoSize.width)) × " + "\(Int(videoSize.height)) video"
        } else {
            sizeDescription = " on this device"
        }
        return XmaxError(
            code: .frameInterpolationUnsupported,
            message: "Frame interpolation is unavailable" + sizeDescription
        )
    }
}

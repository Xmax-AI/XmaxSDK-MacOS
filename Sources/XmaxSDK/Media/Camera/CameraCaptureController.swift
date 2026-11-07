//
//  CameraCaptureController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AVFoundation
import Foundation

/// Captures video with AVFoundation and delivers processed frames.
final class CameraCaptureController: NSObject, CameraCaptureControlling, @unchecked Sendable {

    /// Bounds the buffers retained by preview and RTC when either consumer falls behind.
    private static let outputBufferLimit = 12

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "ai.xmax.sdk.camera", qos: .userInitiated)

    // Mutable session and sample state is confined to captureQueue.
    private var input: AVCaptureDeviceInput?
    private var videoFormat: VideoFormat?
    private var frameRate = 0
    private var captureID: UUID?
    private var rotationObserver: NSKeyValueObservation?
    private var rotationCoordinator: AnyObject?
    private var frameListener: MediaVideoFrameListener?
    private var previewReadyListener: (@Sendable () -> Void)?
    private var errorListener: XmaxErrorListener?
    private var observers: [NSObjectProtocol] = []

    private var lastTimestampUs: Int64?
    private var hasReportedFrameError = false

    /// Reuses IOSurface-backed output buffers for the current dimensions and pixel layout.
    private var outputPool: (width: Int, height: Int, pixelFormat: OSType, pool: CVPixelBufferPool)?

    /// Lists devices without opening the capture session.
    func listCameraDevices() -> [CameraDevice] {
        CameraDeviceDiscovery.availableCameraDevices()
    }

    /// Matches the requested frame rate while accepting small device timing round-off.
    ///
    /// - Parameters:
    ///   - frameRate: The requested nominal frame rate.
    ///   - minimum: The device's shortest supported frame duration.
    ///   - maximum: The device's longest supported frame duration.
    /// - Returns: A supported duration, or nil when the nominal rate is unavailable.
    static func captureFrameDuration(frameRate: Int, minimum: CMTime, maximum: CMTime) -> CMTime? {
        guard frameRate > 0, frameRate <= Int(Int32.max),
              minimum.isNumeric, maximum.isNumeric,
              minimum > .zero, maximum >= minimum else { return nil }
        let requested = CMTime(value: 1, timescale: Int32(frameRate))
        let supported = min(max(requested, minimum), maximum)
        guard abs(1 / supported.seconds - Double(frameRate)) <= 0.1 else { return nil }
        return supported
    }

    /// Starts camera capture and outputs upright NV12 frames at the target dimensions.
    ///
    /// - Parameters:
    ///   - videoFormat: The output pixel format and dimensions.
    ///   - frameRate: The capture frame rate.
    ///   - deviceID: The target camera device identifier.
    ///   - frameListener: Receives video frames on the serial capture queue.
    ///   - errorListener: Receives capture runtime errors.
    /// - Throws: An error on invalid devices or formats, or capture startup failure.
    func start(
        videoFormat: VideoFormat,
        frameRate: Int,
        deviceID: String,
        frameListener: @escaping MediaVideoFrameListener,
        previewReadyListener: @escaping @Sendable () -> Void,
        errorListener: @escaping XmaxErrorListener
    ) async throws {
        try Task.checkCancellation()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            captureQueue.async { [self] in
                guard self.videoFormat == nil else {
                    continuation.resume(throwing: Self.cameraError("Camera capture is already running"))
                    return
                }
                do {
                    guard frameRate > 0, frameRate <= Int(Int32.max),
                          videoFormat.pixelFormat == .nv12,
                          videoFormat.width.isMultiple(of: 2), videoFormat.height.isMultiple(of: 2) else {
                        throw Self.cameraError("Camera capture format is invalid")
                    }

                    self.videoFormat = videoFormat
                    let captureID = UUID()
                    self.captureID = captureID
                    self.frameRate = frameRate
                    self.frameListener = frameListener
                    self.previewReadyListener = previewReadyListener
                    self.errorListener = errorListener

                    session.beginConfiguration()

                    do {
                        session.sessionPreset = .high
                        try replaceInput(deviceID: deviceID)

                        guard session.canAddOutput(output) else {
                            throw Self.cameraError("Camera video output is unavailable")
                        }
                        session.addOutput(output)

                        let preferredFormats = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]
                        guard let pixelFormat = preferredFormats.first(where: output.availableVideoPixelFormatTypes.contains)
                        else { throw Self.cameraError("Camera does not support NV12 or BGRA video output") }
                        output.videoSettings = [
                            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
                        ]
                        output.alwaysDiscardsLateVideoFrames = true
                        output.setSampleBufferDelegate(self, queue: captureQueue)
                        try configureConnection()
                    } catch {
                        session.commitConfiguration()
                        throw error
                    }
                    session.commitConfiguration()

                    observeSession()
                    session.startRunning()
                    guard session.isRunning else {
                        throw Self.cameraError("Camera capture failed to start")
                    }
                    captureQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, self.captureID == captureID, self.previewReadyListener != nil else { return }
                        self.previewReadyListener = nil
                        self.errorListener?(XmaxError(code: .timeout, message: "Camera did not deliver a video frame"))
                    }

                    continuation.resume()
                } catch {
                    stopCapture()
                    continuation.resume(
                        throwing: error as? XmaxError ?? Self.cameraError(error.localizedDescription)
                    )
                }
            }
        }
    }

    /// Switches cameras while retaining output dimensions and frame rate.
    ///
    /// - Parameter deviceID: The target camera device identifier.
    /// - Throws: An error if the device is unavailable or switching fails.
    func switchCamera(to deviceID: String) async throws {
        try Task.checkCancellation()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            captureQueue.async { [self] in
                do {
                    guard videoFormat != nil else {
                        throw Self.cameraError("Camera capture is not running")
                    }

                    session.beginConfiguration()
                    defer {
                        session.commitConfiguration()
                    }

                    let previousInput = input
                    do {
                        try replaceInput(deviceID: deviceID)
                        try configureConnection()
                    } catch {
                        if let input {
                            session.removeInput(input)
                        }
                        input = nil

                        if let previousInput, session.canAddInput(previousInput) {
                            session.addInput(previousInput)
                            input = previousInput
                            try? configureConnection()
                        } else {
                            errorListener?(Self.cameraError("Failed to restore the previous camera"))
                        }

                        throw error
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(
                        throwing: error as? XmaxError ?? Self.cameraError(error.localizedDescription)
                    )
                }
            }
        }
    }

    /// Stops capture, waits for in-flight frames, and releases the device.
    func stop() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [self] in
                stopCapture()
                continuation.resume()
            }
        }
    }

    /// Updates capture dimensions and pacing, restoring the previous format if configuration fails.
    func updateFormat(_ videoFormat: VideoFormat, frameRate: Int) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            captureQueue.async { [self] in
                guard let previousFormat = self.videoFormat, let device = input?.device else {
                    continuation.resume(throwing: Self.cameraError("Camera capture is not running"))
                    return
                }
                let previousRate = self.frameRate
                self.frameRate = frameRate
                do {
                    try configureFormat(on: device)
                    self.videoFormat = videoFormat
                    continuation.resume()
                } catch {
                    self.videoFormat = previousFormat
                    self.frameRate = previousRate
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension CameraCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Converts captured frames to the target dimensions and orientation, using host-clock timestamps for callbacks.
    ///
    /// - Parameters:
    ///   - output: The capture output producing video samples.
    ///   - sampleBuffer: The video sample containing its pixel buffer and capture timestamp.
    ///   - connection: The active video output capture connection.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let videoFormat, let frameListener,
              connection === self.output.connection(with: .video),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        guard let hostTime = session.hostPresentationTime(for: sampleBuffer) else { return }

        let timestampUs = CMTimeConvertScale(
            hostTime,
            timescale: 1000000,
            method: .default
        ).value
        guard timestampUs >= 0, lastTimestampUs.map({ timestampUs > $0 }) ?? true else {
            return
        }
        lastTimestampUs = timestampUs

        do {
            guard let destination = try makeOutputBuffer(
                width: videoFormat.width,
                height: videoFormat.height,
                pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
            ) else { return }
            let frame = try VideoFrameConverter.convert(
                pixelBuffer: pixelBuffer,
                outputWidth: videoFormat.width,
                outputHeight: videoFormat.height,
                timestampUs: timestampUs,
                outputPixelBuffer: destination
            )
            try frameListener(frame)
            previewReadyListener?()
            previewReadyListener = nil
        } catch {
            guard !hasReportedFrameError else {
                return
            }

            hasReportedFrameError = true
            errorListener?(XmaxError.from(error))
        }
    }
}

private extension CameraCaptureController {

    /// Acquires an output buffer on the capture queue, or skips this frame when consumers retain the pool.
    func makeOutputBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) throws -> CVPixelBuffer? {
        let pool: CVPixelBufferPool
        if let existing = outputPool,
            existing.width == width, existing.height == height, existing.pixelFormat == pixelFormat
        {
            pool = existing.pool
        } else {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else {
                throw Self.cameraError("Failed to create camera output pool (\(status))")
            }
            pool = created
            outputPool = (width, height, pixelFormat, created)
        }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            nil,
            pool,
            [kCVPixelBufferPoolAllocationThresholdKey: Self.outputBufferLimit] as CFDictionary,
            &buffer
        )
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == kCVReturnSuccess, let buffer else {
            throw Self.cameraError("Failed to allocate camera output buffer (\(status))")
        }
        return buffer
    }
    /// Replaces camera input and applies a capture format supporting the target frame rate.
    ///
    /// - Parameter deviceID: The target camera device identifier.
    /// - Throws: An error on unavailable cameras, unsupported capture formats, or device configuration failure.
    func replaceInput(deviceID: String) throws {
        guard let device = CameraDeviceDiscovery.captureDevices().first(where: { $0.uniqueID == deviceID }) else {
            throw Self.cameraError("The requested camera is unavailable")
        }

        let newInput = try AVCaptureDeviceInput(device: device)
        if let input { session.removeInput(input) }
        input = nil
        guard session.canAddInput(newInput) else {
            throw Self.cameraError("Failed to attach the requested camera")
        }
        session.addInput(newInput)
        input = newInput
        try configureFormat(on: device)
    }

    /// Selects a supported device format and applies pacing after validating all inputs.
    func configureFormat(on device: AVCaptureDevice) throws {
        // Prefer 16:9 formats up to 1080p, while accepting other device aspect ratios for cropping.
        let selected = device.formats.compactMap { format -> (
            format: AVCaptureDevice.Format, area: Int64, isWide: Bool, duration: CMTime
        )? in
            guard let duration = format.videoSupportedFrameRateRanges.lazy.compactMap({
                Self.captureFrameDuration(frameRate: self.frameRate, minimum: $0.minFrameDuration, maximum: $0.maxFrameDuration)
            }).first else {
                return nil
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let longSide = Int64(max(dimensions.width, dimensions.height))
            let shortSide = Int64(min(dimensions.width, dimensions.height))
            let isWide = longSide * 9 == shortSide * 16
            guard longSide > 0, shortSide > 0,
                  longSide <= 1920, shortSide <= 1440 else {
                return nil
            }

            return (format, longSide * shortSide, isWide, duration)
        }.max { lhs, rhs in
            if lhs.isWide != rhs.isWide {
                return !lhs.isWide
            }

            return lhs.area < rhs.area
        }

        guard let selected else {
            throw Self.cameraError(
                "The camera does not support a compatible format at the requested frame rate"
            )
        }

        try device.lockForConfiguration()
        defer {
            device.unlockForConfiguration()
        }

        device.activeFormat = selected.format
        device.activeVideoMinFrameDuration = selected.duration
        device.activeVideoMaxFrameDuration = selected.duration

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    /// Configures the video capture connection and disables automatic system mirroring.
    ///
    /// - Throws: An error if the capture connection is unavailable or orientation configuration is unsupported.
    func configureConnection() throws {
        guard let connection = output.connection(with: .video) else {
            throw Self.cameraError("Camera video connection is unavailable")
        }
        if #available(macOS 14.0, *), let device = input?.device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            rotationCoordinator = coordinator
            if connection.isVideoRotationAngleSupported(coordinator.videoRotationAngleForHorizonLevelCapture) {
                connection.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelCapture
            }
            rotationObserver = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                let identity = ObjectIdentifier(coordinator)
                self?.captureQueue.async { [weak self] in
                    guard let self, let rotationCoordinator, ObjectIdentifier(rotationCoordinator) == identity,
                        let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle)
                    else { return }
                    connection.videoRotationAngle = angle
                }
            }
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// Observes device disconnection and capture failures, attempting recovery after interruptions end.
    func observeSession() {
        let identity = captureID
        let errorListener = errorListener
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID
            self?.captureQueue.async { [weak self] in
                guard let self, captureID == identity else { return }
                guard input?.device.uniqueID == deviceID else { return }
                errorListener?(Self.cameraError("The active camera was disconnected"))
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = error?.localizedDescription ?? "Camera capture failed"

            self?.captureQueue.async { [weak self] in
                guard let self, captureID == identity else {
                    return
                }

                errorListener?(Self.cameraError(message))
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.captureQueue.async { [weak self] in
                guard let self, captureID == identity, !session.isRunning else {
                    return
                }

                session.startRunning()
                if !session.isRunning {
                    errorListener?(Self.cameraError("Camera capture failed to resume"))
                }
            }
        })
    }

    /// Stops capture and removes inputs, outputs, observers, and frame callbacks.
    func stopCapture() {
        captureID = nil
        rotationObserver = nil
        rotationCoordinator = nil
        frameListener = nil
        previewReadyListener = nil
        errorListener = nil
        videoFormat = nil
        outputPool = nil

        output.setSampleBufferDelegate(nil, queue: nil)
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        session.stopRunning()
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        session.commitConfiguration()

        input = nil
        frameRate = 0
        lastTimestampUs = nil
        hasReportedFrameError = false
    }

    /// Creates a camera capture error.
    ///
    /// - Parameter message: The error description.
    /// - Returns: A media error with the specified description.
    static func cameraError(_ message: String) -> XmaxError {
        XmaxError(code: .mediaError, message: message)
    }
}

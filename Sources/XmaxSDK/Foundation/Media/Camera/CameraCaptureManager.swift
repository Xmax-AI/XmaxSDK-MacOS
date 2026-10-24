//
//  CameraCaptureManager.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AVFoundation
import Foundation

/// Captures video with AVFoundation, serializing device operations and frame handling on one queue.
final class CameraCaptureManager: NSObject, CameraCaptureManaging, @unchecked Sendable {

    /// Platform resources
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "ai.xmax.sdk.camera", qos: .userInitiated)

    /// Capture configuration (captureQueue only)
    private var input: AVCaptureDeviceInput?
    private var videoFormat: VideoFormat?
    private var frameRate = 0

    /// Event listeners
    private var frameListener: (@Sendable (VideoFrame) throws -> Void)?
    private var errorListener: XmaxErrorListener?
    private var observers: [NSObjectProtocol] = []

    /// Runtime state
    private var lastTimestampUs: Int64?
    private var hasReportedFrameError = false
    private var firstFrameTiming: LocalMediaPreparationTiming.Span?

    /// Lists built-in, external, and system Continuity Camera devices.
    ///
    /// - Returns: Selectable devices and their default status.
    func listCameraDevices() -> [CameraDevice] {
        Self.availableCameraDevices()
    }

    /// Device discovery can also be used by RTC capture without creating an AVCaptureSession.
    static func availableCameraDevices() -> [CameraDevice] {
        let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID
        return Self.captureDevices().map { device in
            CameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID,
                position: Self.resolvePosition(device.position, deviceType: device.deviceType)
            )
        }
    }

    /// Converts system camera positions to SDK positions; treats built-in macOS cameras with unknown positions as front-facing.
    ///
    /// - Parameters:
    ///   - position: The camera position reported by the system.
    ///   - deviceType: The device type used to identify built-in cameras.
    /// - Returns: The camera position used for preview mirroring.
    static func resolvePosition(
        _ position: AVCaptureDevice.Position,
        deviceType: AVCaptureDevice.DeviceType
    ) -> CameraPosition {
        if position == .front { return .front }
        if position == .back { return .back }
        return deviceType == .builtInWideAngleCamera ? .front : .unspecified
    }

    /// Lists system video devices without starting capture.
    ///
    /// - Returns: The system's current video capture devices.
    private static func captureDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
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
        guard abs(1 / supported.seconds - Double(frameRate)) <= 0.001 else { return nil }
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
        frameListener: @escaping @Sendable (VideoFrame) throws -> Void,
        errorListener: @escaping XmaxErrorListener
    ) async throws {
        try Task.checkCancellation()

        // Dispatch queues do not inherit task-local values; retain this startup trace explicitly.
        let timingTrace = LocalMediaPreparationTiming.current
        let queueWait = timingTrace?.begin(.captureQueueWait)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            captureQueue.async { [self] in
                queueWait?.finish()
                LocalMediaPreparationTiming.$current.withValue(timingTrace) {
                    do {
                        guard self.videoFormat == nil else {
                            throw Self.cameraError("Camera capture is already running")
                        }
                        guard frameRate > 0, frameRate <= Int(Int32.max),
                              videoFormat.pixelFormat == .nv12,
                              videoFormat.width.isMultiple(of: 2), videoFormat.height.isMultiple(of: 2) else {
                            throw Self.cameraError("Camera capture format is invalid")
                        }

                        self.videoFormat = videoFormat
                        self.frameRate = frameRate
                        self.frameListener = frameListener
                        self.errorListener = errorListener

                        LocalMediaPreparationTiming.measure(.captureBeginConfiguration) {
                            session.beginConfiguration()
                        }

                        do {
                            session.sessionPreset = .high
                            try LocalMediaPreparationTiming.measure(.captureInputSetup) {
                                try replaceInput(deviceID: deviceID)
                            }

                            try LocalMediaPreparationTiming.measure(.captureOutputSetup) {
                                guard session.canAddOutput(output) else {
                                    throw Self.cameraError("Camera video output is unavailable")
                                }
                                session.addOutput(output)

                                guard output.availableVideoPixelFormatTypes.contains(
                                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                ) else {
                                    throw Self.cameraError("Camera does not support NV12 video output")
                                }
                                output.videoSettings = [
                                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                ]
                                output.alwaysDiscardsLateVideoFrames = true
                                output.setSampleBufferDelegate(self, queue: captureQueue)
                                try configureConnection()
                            }
                        } catch {
                            LocalMediaPreparationTiming.measure(.captureCommitConfiguration) {
                                session.commitConfiguration()
                            }
                            throw error
                        }
                        LocalMediaPreparationTiming.measure(.captureCommitConfiguration) {
                            session.commitConfiguration()
                        }

                        observeSession()
                        LocalMediaPreparationTiming.measure(.captureStartRunning) {
                            session.startRunning()
                        }
                        guard session.isRunning else {
                            throw Self.cameraError("Camera capture failed to start")
                        }

                        firstFrameTiming = timingTrace?.begin(.firstCapturedFrame)
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

}

extension CameraCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
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

        let captureClock = session.synchronizationClock

        guard let clock = captureClock else {
            return
        }

        let hostTime = CMSyncConvertTime(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            from: clock,
            to: CMClockGetHostTimeClock()
        )
        guard hostTime.isNumeric else {
            return
        }

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
            let frame = try NV12VideoFrameConverter.convert(
                pixelBuffer: pixelBuffer,
                outputWidth: videoFormat.width,
                outputHeight: videoFormat.height,
                rotation: .rotation0,
                timestampUs: timestampUs
            )
            try frameListener(frame)
            firstFrameTiming?.finish()
            firstFrameTiming = nil
        } catch {
            firstFrameTiming?.finish(.failed)
            firstFrameTiming = nil
            guard !hasReportedFrameError else {
                return
            }

            hasReportedFrameError = true
            XmaxLogger.media.error(message: "摄像头帧处理失败 (Camera Frame Processing Failed)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))\(error.localizedDescription)")
        }
    }
}

private extension CameraCaptureManager {
    /// Replaces camera input and applies a capture format supporting the target frame rate.
    ///
    /// - Parameter deviceID: The target camera device identifier.
    /// - Throws: An error on unavailable cameras, unsupported capture formats, or device configuration failure.
    func replaceInput(deviceID: String) throws {
        let device = try LocalMediaPreparationTiming.measure(.captureDeviceDiscovery) {
            guard let device = Self.captureDevices().first(where: { $0.uniqueID == deviceID }) else {
                throw Self.cameraError("The requested camera is unavailable")
            }
            return device
        }

        // Prefers 16:9 formats up to 1920×1080, falling back to 4:3 formats up to 1920×1440.
        let selected = LocalMediaPreparationTiming.measure(.captureFormatSelection) {
            device.formats.compactMap { format -> (
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
                      longSide <= 1920, shortSide <= 1440,
                      isWide || longSide * 3 == shortSide * 4 else {
                    return nil
                }

                return (format, longSide * shortSide, isWide, duration)
            }.max { lhs, rhs in
                if lhs.isWide != rhs.isWide {
                    return !lhs.isWide
                }

                return lhs.area < rhs.area
            }
        }

        guard let selected else {
            throw Self.cameraError(
                "The camera does not support a compatible 16:9 or 4:3 format at the requested frame rate"
            )
        }

        let newInput = try LocalMediaPreparationTiming.measure(.captureInputCreate) {
            try AVCaptureDeviceInput(device: device)
        }
        if let input {
            session.removeInput(input)
        }
        input = nil

        guard session.canAddInput(newInput) else {
            throw Self.cameraError("Failed to attach the requested camera")
        }
        session.addInput(newInput)
        input = newInput

        try LocalMediaPreparationTiming.measure(.captureDeviceConfiguration) {
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
    }

    /// Configures the video capture connection and disables automatic system mirroring.
    ///
    /// - Throws: An error if the capture connection is unavailable or orientation configuration is unsupported.
    func configureConnection() throws {
        guard let connection = output.connection(with: .video) else {
            throw Self.cameraError("Camera video connection is unavailable")
        }
        // Native macOS uses device output orientation independently of window layout.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// Observes device disconnection and capture failures, attempting recovery after interruptions end.
    func observeSession() {
        let errorListener = errorListener
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID
            self?.captureQueue.async { [weak self] in
                guard let self, videoFormat != nil, input?.device.uniqueID == deviceID else { return }
                errorListener?(Self.cameraError("The active camera was disconnected"))
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = error?.localizedDescription ?? "Camera capture failed"

            self?.captureQueue.async { [weak self] in
                guard let self, videoFormat != nil else {
                    return
                }

                errorListener?(Self.cameraError(message))
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.captureQueue.async { [weak self] in
                guard let self, videoFormat != nil, !session.isRunning else {
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
        firstFrameTiming?.finish(.cancelled)
        firstFrameTiming = nil
        frameListener = nil
        errorListener = nil
        videoFormat = nil

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

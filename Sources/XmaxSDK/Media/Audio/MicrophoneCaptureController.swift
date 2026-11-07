//
//  MicrophoneCaptureController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Owns the selected physical microphone and its PCM delivery.
protocol MicrophoneCaptureControlling: Sendable {

    /// Selects the input UID or the system default when nil.
    func selectDevice(
        _ deviceID: String?
    ) throws

    /// Starts delivering PCM on the shared monotonic timeline.
    func start(
        frameListener: @escaping MediaAudioFrameListener
    ) throws

    /// Stops capture while retaining the selected device.
    func stop()

    /// Observes the microphone's input level on the main actor.
    @MainActor
    func setLevelListener(
        _ listener: RealtimeMicrophoneLevelListener?
    )
}

/// Captures microphone PCM on its own session and queue, independent of video capture.
final class MicrophoneCaptureController: NSObject, MicrophoneCaptureControlling, @unchecked Sendable {

    /// The Core Audio property identifying the system default microphone.
    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "ai.xmax.sdk.microphone", qos: .userInitiated)
    private let levels = MicrophoneLevelMonitor()

    // Session configuration and sample delivery are serialized on queue.
    private var input: AVCaptureDeviceInput?
    private var deviceID: String?
    private var converter: ExternalAudioFrameConverter?
    private var frameListener: MediaAudioFrameListener?
    private var captureID: UUID?
    private var defaultInputObserver: AudioObjectPropertyListenerBlock?
    private var observers: [NSObjectProtocol] = []
    private var inputStartTime = CMTime.invalid
    private var lastLevelTime: Int64?

    /// Stores the selected UID and updates the running audio session if needed.
    func selectDevice(_ deviceID: String?) throws {
        try queue.sync {
            if captureID != nil {
                let device = try Self.resolveDevice(deviceID)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                try replaceInput(with: device)
            } else if deviceID != nil {
                _ = try Self.resolveDevice(deviceID)
            }
            self.deviceID = deviceID
        }
    }

    /// Starts delivering timestamped PCM on the serial microphone queue.
    func start(frameListener: @escaping MediaAudioFrameListener) throws {
        try queue.sync {
            guard captureID == nil else { return }
            let device = try Self.resolveDevice(deviceID)
            session.beginConfiguration()
            do {
                try replaceInput(with: device)
                guard session.canAddOutput(output) else {
                    throw Self.captureError("Microphone audio output is unavailable")
                }
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: queue)
            } catch {
                session.commitConfiguration()
                stopCapture()
                throw error
            }
            session.commitConfiguration()

            let captureID = UUID()
            self.captureID = captureID
            self.frameListener = frameListener
            observeCapture(captureID)
            session.startRunning()
            guard session.isRunning else {
                stopCapture()
                throw Self.captureError("Microphone capture failed to start")
            }
        }
    }

    /// Stops delivery and releases the physical microphone while retaining its selection.
    func stop() {
        queue.sync {
            guard captureID != nil else { return }
            stopCapture()
        }
    }

    /// Replays the current physical input reading on the main actor.
    @MainActor
    func setLevelListener(_ listener: RealtimeMicrophoneLevelListener?) {
        levels.setListener(listener)
    }
}

extension MicrophoneCaptureController: AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Converts and publishes PCM using the same monotonic timeline as the video frames.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let converter, let frameListener,
            connection === self.output.connection(with: .audio),
            let timestamp = session.hostPresentationTime(for: sampleBuffer), timestamp >= inputStartTime
        else { return }
        do {
            try converter.append(sampleBuffer, presentationTime: timestamp) { [self] frame in
                publishLevel(for: frame)
                try frameListener(frame)
            }
        } catch {
            suspendCapture(error)
        }
    }
}

private extension MicrophoneCaptureController {

    /// Resolves an explicit UID or the current default without opening the input.
    static func resolveDevice(_ deviceID: String?) throws -> AVCaptureDevice {
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }
        guard let device, device.isConnected, device.hasMediaType(.audio) else {
            throw captureError("The requested microphone is unavailable")
        }
        return device
    }

    /// Replaces the input within a session configuration, restoring the previous route on failure.
    func replaceInput(with device: AVCaptureDevice) throws {
        guard input?.device.uniqueID != device.uniqueID || converter == nil else { return }
        let replacement = try AVCaptureDeviceInput(device: device)
        let previous = input
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(replacement) else {
            if let previous, session.canAddInput(previous) {
                session.addInput(previous)
            } else {
                input = nil
                converter = nil
                levels.endCapture()
            }
            throw Self.captureError("Failed to attach the requested microphone")
        }
        session.addInput(replacement)
        input = replacement
        resetInputTimeline()
    }

    /// Discards queued samples from the previous route and starts a new PCM segment.
    func resetInputTimeline() {
        converter = ExternalAudioFrameConverter()
        inputStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        lastLevelTime = nil
        levels.beginCapture()
    }

    /// Measures input peak strength at most once every 200 ms.
    func publishLevel(for frame: AudioFrame) {
        guard let listener = levels.sourceListener(),
            lastLevelTime.map({ frame.timestampUs - $0 >= 200_000 }) ?? true
        else { return }
        lastLevelTime = frame.timestampUs
        let peak = frame.data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: MemoryLayout<Int16>.size).reduce(0) { peak, offset in
                max(peak, abs(Int(bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))))
            }
        }
        listener(Float(peak) / 32_768)
    }

    /// Clears unusable audio and keeps the current route available for recovery or switching.
    func suspendCapture(_ error: any Error) {
        converter = nil
        levels.endCapture()
        XmaxLogger.media.warn(message: "Microphone input is unavailable: \(error.localizedDescription)")
    }

    /// Observes route changes and device or session failures for this capture only.
    func observeCapture(_ captureID: UUID) {
        var address = Self.defaultInputAddress
        let observer: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.captureID == captureID, deviceID == nil else { return }
            do {
                let device = try Self.resolveDevice(nil)
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                try replaceInput(with: device)
            } catch {
                suspendCapture(error)
            }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, observer
        ) == noErr {
            defaultInputObserver = observer
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let removedID = (notification.object as? AVCaptureDevice)?.uniqueID
            self?.queue.async { [weak self] in
                guard let self, self.captureID == captureID, let removedID,
                    input?.device.uniqueID == removedID, deviceID != nil
                else { return }
                suspendCapture(Self.captureError("The active microphone was disconnected"))
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
            self?.queue.async { [weak self] in
                guard let self, self.captureID == captureID else { return }
                suspendCapture(Self.captureError(message ?? "Microphone capture failed"))
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.captureID == captureID, input != nil else { return }
                if !session.isRunning { session.startRunning() }
                if session.isRunning {
                    resetInputTimeline()
                } else {
                    suspendCapture(Self.captureError("Microphone capture failed to resume"))
                }
            }
        })
    }

    /// Stops the audio session and invalidates callbacks before releasing its inputs and outputs.
    func stopCapture() {
        captureID = nil
        frameListener = nil
        converter = nil
        levels.endCapture()
        if let defaultInputObserver {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, defaultInputObserver
            )
            self.defaultInputObserver = nil
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        input = nil
        if session.outputs.contains(where: { $0 === output }) { session.removeOutput(output) }
        session.commitConfiguration()
    }

    static func captureError(_ message: String) -> XmaxError {
        XmaxError(code: .mediaError, message: message)
    }
}

extension AVCaptureSession {

    /// Converts a capture output timestamp from its session clock to the shared host timeline.
    func hostPresentationTime(for sampleBuffer: CMSampleBuffer) -> CMTime? {
        guard let synchronizationClock else { return nil }
        let timestamp = CMSyncConvertTime(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            from: synchronizationClock,
            to: CMClockGetHostTimeClock()
        )
        return timestamp.isNumeric && timestamp >= .zero ? timestamp : nil
    }
}

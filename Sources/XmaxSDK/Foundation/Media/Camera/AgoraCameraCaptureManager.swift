//
//  AgoraCameraCaptureManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// A camera capture adapter that serializes native control and observes readiness without raw pixel delivery.
final class AgoraCameraCaptureManager: CameraCaptureManaging, @unchecked Sendable {

    /// The RTC manager owning native camera capture.
    private let rtcManager: any RtcManaging

    /// The device discovery operation, independent of capture startup.
    private let listDevices: @Sendable () -> [CameraDevice]

    /// The maximum wait for native capture readiness.
    private let startupTimeout: Duration

    /// The serial queue for native camera control operations.
    private let queue = DispatchQueue(
        label: "ai.xmax.sdk.agora-camera",
        qos: .userInitiated
    )

    /// The lock protecting the readiness callback.
    private let stateLock = NSLock()

    /// The listener notified when native capture is usable.
    private var previewReadyListener: (@Sendable () -> Void)?

    /// Creates a native camera controller with device discovery and a readiness timeout.
    init(
        rtcManager: any RtcManaging,
        listDevices: @escaping @Sendable () -> [CameraDevice] = CameraCaptureManager.availableCameraDevices,
        startupTimeout: Duration = .seconds(10)
    ) {
        self.rtcManager = rtcManager
        self.listDevices = listDevices
        self.startupTimeout = startupTimeout
    }

    /// Whether capture feeds RTC directly without decoded frame submission.
    var suppliesRTCVideo: Bool { true }

    /// Lists camera devices without starting capture.
    func listCameraDevices() -> [CameraDevice] { listDevices() }

    /// Replaces the callback for native capture readiness.
    func setNativePreviewReadyListener(
        _ listener: (@Sendable () -> Void)?
    ) {
        stateLock.withLock { previewReadyListener = listener }
    }

    /// Starts native capture and waits for readiness, cancellation, or timeout.
    ///
    /// Agora owns local rendering and RTC video delivery; this implementation does not invoke the raw frame listener.
    func start(
        videoFormat: VideoFormat,
        frameRate: Int,
        deviceID: String,
        frameListener: @escaping @Sendable (VideoFrame) throws -> Void,
        errorListener: @escaping XmaxErrorListener
    ) async throws {
        try Task.checkCancellation()
        let readyListener = stateLock.withLock { previewReadyListener }
        let (events, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        queue.async { [rtcManager] in
            do {
                try rtcManager.startCameraCapture(
                    configuration: RtcCameraConfiguration(
                        deviceID: deviceID,
                        width: videoFormat.width,
                        height: videoFormat.height,
                        frameRate: frameRate
                    ),
                    previewReadyListener: {
                        readyListener?()
                        continuation.yield(())
                        continuation.finish()
                    },
                    errorListener: { error in
                        continuation.finish(throwing: error)
                        errorListener(error)
                    }
                )
            } catch { continuation.finish(throwing: error) }
        }
        // Wait asynchronously for native capture to start, before an AppKit view calls setupLocalVideo.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                guard try await iterator.next() != nil else {
                    try Task.checkCancellation()
                    throw XmaxError(
                        code: .cancelled,
                        message: "Native camera startup was cancelled"
                    )
                }
            }
            group.addTask { [startupTimeout] in
                try await Task.sleep(for: startupTimeout)
                throw XmaxError(
                    code: .timeout,
                    message: "Native camera capture did not become ready"
                )
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        try Task.checkCancellation()
    }

    /// Switches the native capture device on the camera control queue.
    func switchCamera(
        to deviceID: String
    ) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [rtcManager] in
                do {
                    try rtcManager.switchCameraCapture(to: deviceID)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Clears readiness observation and stops native capture on the control queue.
    func stop() async {
        setNativePreviewReadyListener(nil)
        await withCheckedContinuation { continuation in
            queue.async { [rtcManager] in
                do { try rtcManager.stopCameraCapture() } catch {
                    XmaxLogger.media.error(message: "Failed to stop RTC camera capture: \(error.localizedDescription)")
                }
                continuation.resume()
            }
        }
    }
}

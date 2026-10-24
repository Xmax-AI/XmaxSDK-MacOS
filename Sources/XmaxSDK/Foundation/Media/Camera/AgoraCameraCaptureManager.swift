import Foundation

/// Runs camera control on a serial queue; Agora delivers preview frames without acquiring control locks.
final class AgoraCameraCaptureManager: CameraCaptureManaging, @unchecked Sendable {
    private let rtcManager: any RtcManaging
    private let listDevices: @Sendable () -> [CameraDevice]
    private let startupTimeout: Duration
    private let queue = DispatchQueue(label: "ai.xmax.sdk.agora-camera", qos: .userInitiated)
    private let stateLock = NSLock()
    private var previewReadyListener: (@Sendable () -> Void)?

    init(
        rtcManager: any RtcManaging,
        listDevices: @escaping @Sendable () -> [CameraDevice] = CameraCaptureManager.availableCameraDevices,
        startupTimeout: Duration = .seconds(10)
    ) {
        self.rtcManager = rtcManager
        self.listDevices = listDevices
        self.startupTimeout = startupTimeout
    }

    var suppliesRTCVideo: Bool { true }

    func listCameraDevices() -> [CameraDevice] { listDevices() }

    func setNativePreviewReadyListener(_ listener: (@Sendable () -> Void)?) {
        stateLock.withLock { previewReadyListener = listener }
    }

    func start(
        videoFormat: VideoFormat, frameRate: Int, deviceID: String,
        frameListener: @escaping @Sendable (VideoFrame) throws -> Void,
        errorListener: @escaping XmaxErrorListener
    ) async throws {
        try Task.checkCancellation()
        let trace = LocalMediaPreparationTiming.current
        let readyListener = stateLock.withLock { previewReadyListener }
        let wait = trace?.begin(.captureQueueWait)
        let (events, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        queue.async { [rtcManager] in
            wait?.finish()
            LocalMediaPreparationTiming.$current.withValue(trace) {
                do {
                    try rtcManager.startCameraCapture(
                        configuration: RtcCameraConfiguration(
                            deviceID: deviceID, width: videoFormat.width, height: videoFormat.height, frameRate: frameRate
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
        }
        // Wait asynchronously for native capture to start, before an AppKit view calls setupLocalVideo.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                guard try await iterator.next() != nil else {
                    try Task.checkCancellation()
                    throw XmaxError(code: .cancelled, message: "Native camera startup was cancelled")
                }
            }
            group.addTask { [startupTimeout] in
                try await Task.sleep(for: startupTimeout)
                throw XmaxError(code: .timeout, message: "Native camera capture did not become ready")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        try Task.checkCancellation()
    }

    func switchCamera(to deviceID: String) async throws {
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

    func stop() async {
        setNativePreviewReadyListener(nil)
        await withCheckedContinuation { continuation in
            queue.async { [rtcManager] in
                do { try rtcManager.stopCameraCapture() }
                catch { XmaxLogger.media.error(message: "Failed to stop RTC camera capture: \(error.localizedDescription)") }
                continuation.resume()
            }
        }
    }
}

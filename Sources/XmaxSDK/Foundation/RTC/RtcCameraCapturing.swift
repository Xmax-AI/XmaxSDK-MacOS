import Foundation
import AppKit

/// Native camera capture and local preview are owned by the RTC engine.
struct RtcCameraConfiguration: Sendable, Equatable {
    let deviceID: String
    let width: Int
    let height: Int
    let frameRate: Int
}

protocol RtcCameraCapturing: Sendable {
    func startCameraCapture(
        configuration: RtcCameraConfiguration,
        previewReadyListener: @escaping @Sendable () -> Void,
        errorListener: @escaping XmaxErrorListener
    ) throws
    func switchCameraCapture(to deviceID: String) throws
    func stopCameraCapture() throws
    @MainActor func attachCameraPreview(to view: NSView, contentMode: VideoContentMode, mirrored: Bool) throws
    @MainActor func detachCameraPreview(from view: NSView) throws
}

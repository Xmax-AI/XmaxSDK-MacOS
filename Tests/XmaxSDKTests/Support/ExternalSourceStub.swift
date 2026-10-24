import AppKit
import XCTest
@testable import XmaxSDK

@MainActor
final class ExternalSourceStub: RealtimeExternalVideoSource {

    /// Source configuration
    let videoFormat: RealtimeVideoFormat
    var startError: (any Error)?
    var startHandler: (@MainActor () async throws -> Void)?
    let captureRunning = true

    /// Binding and preview state
    var sink: (any RealtimeExternalFrameSink)?
    var lastSink: (any RealtimeExternalFrameSink)?
    var stops = 0
    var previewContainer: NSView?
    var contentMode: VideoContentMode?
    var detachments = 0

    init(videoFormat: RealtimeVideoFormat = RealtimeVideoFormat(width: 4, height: 4, fps: 60)) {
        self.videoFormat = videoFormat
    }

    func start(sink: any RealtimeExternalFrameSink) async throws {
        self.sink = sink
        lastSink = sink
        if let startError { throw startError }
        try await startHandler?()
    }

    func stop() async {
        sink = nil
        stops += 1
    }

    func attachPreview(to container: NSView, contentMode: VideoContentMode) {
        previewContainer = container
        self.contentMode = contentMode
    }

    func detachPreview(from container: NSView) {
        XCTAssertTrue(previewContainer === container)
        previewContainer = nil
        detachments += 1
    }
}

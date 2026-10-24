import AppKit

/// Binds an SDK view to Agora's native renderer without reading or copying local video pixels.
@MainActor
final class RtcCameraPreviewPresenter {
    private let rtcManager: any RtcManaging
    private weak var view: XmaxVideoView?
    private weak var canvasView: NSView?
    private var contentMode: VideoContentMode = .fill
    private var sourceMirrored: Bool

    init(rtcManager: any RtcManaging, mirrored: Bool) {
        self.rtcManager = rtcManager
        sourceMirrored = mirrored
    }

    func attach(to view: XmaxVideoView, contentMode: VideoContentMode) throws {
        self.view = view
        self.contentMode = contentMode
        canvasView = view.prepareNativeVideoPreview()
        view.nativePreviewUpdateHandler = { [weak self] in
            do { try self?.update() }
            catch { XmaxVideoView.logRenderingFailure(title: "Failed to update native camera preview", error: error) }
        }
        try update()
    }

    func setMirrored(_ mirrored: Bool) throws {
        sourceMirrored = mirrored
        try update()
    }

    func detach(from view: XmaxVideoView) throws {
        guard self.view === view else { return }
        try clear()
    }

    func clear() throws {
        defer {
            view?.clearNativeVideoPreview()
            view = nil
            canvasView = nil
        }
        if let canvasView { try rtcManager.detachCameraPreview(from: canvasView) }
    }

    private func update() throws {
        guard let view, let canvasView else { return }
        try rtcManager.attachCameraPreview(to: canvasView, contentMode: contentMode,
                                          mirrored: sourceMirrored || view.isMirrored)
    }
}

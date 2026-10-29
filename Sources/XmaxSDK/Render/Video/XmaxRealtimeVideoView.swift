//
//  XmaxRealtimeVideoView.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import QuartzCore

/// An AppKit view rendering one local or remote realtime video track.
@MainActor
public final class XmaxRealtimeVideoView: NSView {

    /// The displayed video track; nil clears the binding.
    public var track: RealtimeVideoTrack? {
        didSet {
            guard oldValue !== track else { return }
            detach(track: oldValue)
            attachCurrentTrackIfNeeded()
        }
    }

    /// The video content display mode in its container.
    public var videoContentMode: VideoContentMode = .fill {
        didSet {
            guard oldValue != videoContentMode else { return }
            attachCurrentTrackIfNeeded()
            updateTrajectoryConfiguration()
        }
    }

    /// The first frame's fade-in duration, in seconds. The default is zero.
    ///
    /// The animation begins when a decoded frame is submitted or native preview is attached.
    /// Zero, negative, or nonfinite values and Reduce Motion disable the animation.
    /// Changes apply to the next track binding; subsequent frames do not restart the fade-in.
    /// The animation affects view presentation only; frame callbacks retain the video pixels.
    public var fadeInDuration: TimeInterval = 0

    /// Enables pointer trajectories on a ready remote generation track.
    public var isInteractionEnabled = true {
        didSet { updateTrajectoryConfiguration() }
    }

    /// Mirrors the video horizontally. Interaction coordinates still follow the displayed pointer.
    public var isMirrored = false {
        didSet {
            applyPreviewMirroring()
            nativePreviewUpdateHandler?()
            updateTrajectoryConfiguration()
        }
    }

    /// Overrides trajectory visuals only; nil restores the SDK's green glow effect.
    public var trajectoryRenderer: (any TrajectoryEffectRendering)? {
        didSet {
            guard oldValue !== trajectoryRenderer else { return }
            trajectoryOverlay?.setRenderer(trajectoryRenderer ?? DefaultTrajectoryEffectRenderer())
        }
    }

    /// The overlay collecting remote pointer gestures and drawing effects.
    private var trajectoryOverlay: TrajectoryOverlayView?

    /// The registered interaction binding for the displayed remote track.
    private weak var trajectoryBinding: TrajectoryBinding?

    /// Whether the local source requires mirrored presentation.
    private var sourceMirrored = false

    /// The track attached for rendering.
    private weak var attachedTrack: RealtimeVideoTrack?

    /// Whether the current binding is waiting for its first submitted frame or native preview.
    private var isWaitingForFirstFrame = true

    /// The internal handler after a valid frame is submitted.
    var frameDisplayHandler: (() -> Void)?

    /// The callback reapplying native preview configuration after view changes.
    var nativePreviewUpdateHandler: (() -> Void)?

    /// The child canvas owned by the native camera renderer.
    private var nativeVideoPreview: NSView?

    /// The decoded frame display layer.
    private var decodedVideoLayer: AVSampleBufferDisplayLayer?

    /// The decoded preview playback timebase.
    private var decodedVideoTimebase: CMTimebase?

    /// The next decoded frame's presentation time.
    private var nextDecodedVideoPresentationTime = CMTime.invalid

    /// The reusable local preview pixel pool.
    private var localPreviewPixelBufferPool: CVPixelBufferPool?

    /// The current local preview frame format.
    private var localPreviewFormat: VideoFormat?

    /// The reusable preview media format description.
    private var localPreviewFormatDescription: CMVideoFormatDescription?

    /// Creates a video container with the specified track and display mode.
    ///
    /// - Parameters:
    ///   - track: The video track to display; may be assigned later.
    ///   - videoContentMode: The video content scaling and cropping mode.
    ///   - fadeInDuration: The first-frame fade-in duration, in seconds; zero disables animation.
    ///   - isInteractionEnabled: Whether to accept pointer trajectories on a ready result.
    public init(
        track: RealtimeVideoTrack? = nil,
        videoContentMode: VideoContentMode = .fill,
        fadeInDuration: TimeInterval = 0,
        isInteractionEnabled: Bool = true
    ) {
        self.track = track
        self.videoContentMode = videoContentMode
        self.fadeInDuration = fadeInDuration
        self.isInteractionEnabled = isInteractionEnabled
        super.init(frame: .zero)
        configureView()
    }

    /// Creates a video container with the specified frame.
    ///
    /// - Parameter frame: The initial view frame.
    public override init(
        frame: CGRect
    ) {
        super.init(frame: frame)
        configureView()
    }

    /// Restores a video container from an Interface Builder archive.
    ///
    /// - Parameter coder: The view archive decoder.
    public required init?(
        coder: NSCoder
    ) {
        super.init(coder: coder)
        configureView()
    }

    /// Unbinds the track and releases preview resources when the view is destroyed.
    isolated deinit {
        detach(track: attachedTrack)
    }

    /// Synchronizes track binding with window attachment state.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detach(track: attachedTrack)
        } else {
            attachCurrentTrackIfNeeded()
        }
    }

    /// Updates layer layout without changing media format or realtime connection.
    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        decodedVideoLayer?.frame = bounds
        nativeVideoPreview?.frame = bounds
        CATransaction.commit()
        trajectoryOverlay?.frame = bounds
    }

    /// Uses top-down view coordinates.
    public override var isFlipped: Bool { true }

    /// Creates a layer container with a black background.
    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }
}

extension XmaxRealtimeVideoView {

    /// Starts the binding's fade-in once and preserves the internal frame notification.
    func notifyVideoFrameSubmitted() {
        if isWaitingForFirstFrame {
            isWaitingForFirstFrame = false
            let duration = fadeInDuration
            if duration.isFinite, duration > 0,
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = duration
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer?.add(
                    fade,
                    forKey: "videoFadeIn"
                )
            }
        }
        frameDisplayHandler?()
    }

    /// Cancels this view's fade-in and prepares the next render binding.
    private func resetFadeIn() {
        layer?.removeAnimation(forKey: "videoFadeIn")
        isWaitingForFirstFrame = true
    }

    /// Agora owns rendering inside this child view; SDK sample-buffer rendering is bypassed.
    func prepareNativeVideoPreview() -> NSView {
        if let nativeVideoPreview { return nativeVideoPreview }
        clearDecodedVideoPreview()
        let view = NSView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        addSubview(
            view,
            positioned: .below,
            relativeTo: nil
        )
        nativeVideoPreview = view
        return view
    }

    /// Removes the native canvas and its update callback.
    func clearNativeVideoPreview() {
        resetFadeIn()
        nativePreviewUpdateHandler = nil
        nativeVideoPreview?.removeFromSuperview()
        nativeVideoPreview = nil
    }

    /// Applies effective mirroring to the decoded video layer.
    private func applyPreviewMirroring() {
        decodedVideoLayer?.setAffineTransform(
            CGAffineTransform(
                scaleX: isMirrored || sourceMirrored ? -1 : 1,
                y: 1
            )
        )
    }

    /// Attaches the registered remote interaction binding to an overlay.
    private func attachTrajectory(
        for track: RealtimeVideoTrack
    ) {
        guard let binding = TrajectoryRegistry.binding(for: track) else { return }
        if trajectoryOverlay == nil {
            let overlay = TrajectoryOverlayView(
                renderer: trajectoryRenderer ?? DefaultTrajectoryEffectRenderer()
            )
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay)
            trajectoryOverlay = overlay
        }
        guard let trajectoryOverlay else { return }
        if trajectoryBinding !== binding {
            trajectoryBinding?.detach(from: trajectoryOverlay)
            trajectoryBinding = binding
            binding.attach(to: trajectoryOverlay)
        }
        updateTrajectoryConfiguration()
    }

    /// Updates pointer presentation without changing the binding's resolved media dimensions.
    private func updateTrajectoryConfiguration() {
        trajectoryOverlay?.configure(
            contentMode: videoContentMode,
            mirrored: isMirrored || sourceMirrored,
            requested: isInteractionEnabled
        )
    }

    /// Creates or updates the decoded video layer and its display clock.
    ///
    /// - Parameter contentMode: The video scaling and cropping mode.
    func prepareDecodedVideoPreview(
        contentMode: VideoContentMode
    ) {
        let decodedVideoLayer: AVSampleBufferDisplayLayer
        if let currentLayer = self.decodedVideoLayer {
            decodedVideoLayer = currentLayer
        } else {
            decodedVideoLayer = AVSampleBufferDisplayLayer()
            // Updates video with rotation layout immediately, avoiding implicit sublayer scaling or flip animations.
            decodedVideoLayer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "transform": NSNull(),
                "videoGravity": NSNull()
            ]
            decodedVideoLayer.frame = bounds
            layer?.insertSublayer(
                decodedVideoLayer,
                at: 0
            )
            self.decodedVideoLayer = decodedVideoLayer

            var timebase: CMTimebase?
            let status = CMTimebaseCreateWithSourceClock(
                allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(),
                timebaseOut: &timebase
            )
            if status == noErr, let timebase {
                CMTimebaseSetTime(
                    timebase,
                    time: .zero
                )
                CMTimebaseSetRate(
                    timebase,
                    rate: 1
                )
                decodedVideoLayer.controlTimebase = timebase
                decodedVideoTimebase = timebase
            }
        }
        decodedVideoLayer.videoGravity = contentMode == .fit ? .resizeAspect : .resizeAspectFill
        applyPreviewMirroring()
    }

    /// Sets horizontal mirroring for decoded video preview.
    ///
    /// - Parameter mirrored: Whether to mirror video horizontally.
    func setDecodedVideoPreviewMirrored(
        _ mirrored: Bool
    ) {
        sourceMirrored = mirrored
        applyPreviewMirroring()
        updateTrajectoryConfiguration()
    }

    /// Converts local NV12 or BGRA frames to samples and submits them for immediate preview.
    ///
    /// - Parameters:
    ///   - frame: The local video frame to display.
    ///   - contentMode: The video scaling and cropping mode.
    func displayDecodedVideoFrame(
        _ frame: VideoFrame,
        contentMode: VideoContentMode
    ) {
        if decodedVideoLayer == nil {
            prepareDecodedVideoPreview(contentMode: contentMode)
        }
        guard let decodedVideoLayer,
            let decodedVideoTimebase
        else {
            return
        }
        decodedVideoLayer.videoGravity = contentMode == .fit ? .resizeAspect : .resizeAspectFill
        if decodedVideoLayer.requiresFlushToResumeDecoding {
            decodedVideoLayer.flush()
        }

        do {
            let pixelBuffer = try makeLocalPreviewPixelBuffer(frame)
            let formatDescription = try localPreviewDescription(for: pixelBuffer)
            let presentationTime = CMTimebaseGetTime(decodedVideoTimebase)
            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: presentationTime,
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            guard
                CMSampleBufferCreateReadyWithImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: pixelBuffer,
                    formatDescription: formatDescription,
                    sampleTiming: &timing,
                    sampleBufferOut: &sampleBuffer
                ) == noErr,
                let sampleBuffer
            else {
                throw Self.invalidImageFrameError
            }
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_DisplayImmediately,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
            decodedVideoLayer.enqueue(sampleBuffer)
            notifyVideoFrameSubmitted()
        } catch {
            Self.logRenderingFailure(
                title: "显示本地视频帧失败 (Failed to Display Local Video Frame)",
                error: error
            )
        }
    }

    /// Submits processed remote frames with their durations for display.
    ///
    /// - Parameters:
    ///   - frame: The remote video frame after interpolation and other processing.
    ///   - contentMode: The video scaling and cropping mode.
    func displayRemoteVideoFrame(
        _ frame: RealtimeVideoFrame,
        contentMode: VideoContentMode
    ) {
        if decodedVideoLayer == nil {
            prepareDecodedVideoPreview(contentMode: contentMode)
        }
        guard let decodedVideoLayer,
            let decodedVideoTimebase
        else {
            return
        }
        decodedVideoLayer.videoGravity = contentMode == .fit ? .resizeAspect : .resizeAspectFill
        if decodedVideoLayer.requiresFlushToResumeDecoding {
            decodedVideoLayer.flush()
            nextDecodedVideoPresentationTime = .invalid
        }

        var formatDescription: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &formatDescription
            ) == noErr,
            let formatDescription
        else {
            return
        }

        let currentTime = CMTimebaseGetTime(decodedVideoTimebase)
        let presentationTime: CMTime
        if nextDecodedVideoPresentationTime.isValid,
            nextDecodedVideoPresentationTime >= currentTime
        {
            presentationTime = nextDecodedVideoPresentationTime
        } else {
            presentationTime = currentTime
        }
        let duration =
            frame.duration.isValid && frame.duration > .zero
            ? frame.duration
            : CMTime(
                value: 1,
                timescale: 24
            )
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ) == noErr,
            let sampleBuffer
        else {
            return
        }
        decodedVideoLayer.enqueue(sampleBuffer)
        nextDecodedVideoPresentationTime = presentationTime + duration
        notifyVideoFrameSubmitted()
    }

    /// Removes video layers and releases display clock and preview buffers.
    func clearDecodedVideoPreview() {
        resetFadeIn()
        decodedVideoLayer?.flushAndRemoveImage()
        decodedVideoLayer?.controlTimebase = nil
        decodedVideoLayer?.removeFromSuperlayer()
        decodedVideoLayer = nil
        decodedVideoTimebase = nil
        nextDecodedVideoPresentationTime = .invalid
        localPreviewPixelBufferPool = nil
        localPreviewFormat = nil
        localPreviewFormatDescription = nil
    }

    /// Logs rendering errors using the unified error description.
    ///
    /// - Parameters:
    ///   - title: The Chinese and English log titles.
    ///   - error: The rendering error to log.
    static func logRenderingFailure(
        title: String,
        error: any Error
    ) {
        XmaxLogger.render.error(
            message: "\(title)\n└─ \(XmaxLogger.localized("原因：", "Reason: "))" + (error as NSError).localizedDescription
        )
    }

    /// Binds the current track to preview after the view joins a window.
    func attachCurrentTrackIfNeeded() {
        guard window != nil, let track,
            let binding = VideoRenderRegistry.binding(for: track)
        else { return }
        do {
            try binding.attach(
                to: self,
                contentMode: videoContentMode
            )
            attachedTrack = track
            attachTrajectory(for: track)
        } catch {
            attachedTrack = nil
            Self.logRenderingFailure(
                title: "绑定视频视图失败 (Failed to Attach Video View)",
                error: error
            )
        }
    }

    /// Unbinds the current view's track while retaining capture and transport.
    ///
    /// - Parameter track: The track to unbind; nil does nothing.
    func detach(
        track: RealtimeVideoTrack?
    ) {
        resetFadeIn()
        guard let track, attachedTrack === track else { return }
        if let trajectoryOverlay {
            trajectoryBinding?.detach(from: trajectoryOverlay)
            trajectoryOverlay.cancelInteraction()
            trajectoryOverlay.removeFromSuperview()
        }
        trajectoryOverlay = nil
        trajectoryBinding = nil
        sourceMirrored = false
        do {
            try VideoRenderRegistry.binding(for: track)?.detach(from: self)
        } catch {
            Self.logRenderingFailure(
                title: "解除视频视图失败 (Failed to Detach Video View)",
                error: error
            )
        }
        attachedTrack = nil
    }

    /// Reuses a matching buffer pool to create a preview buffer.
    ///
    /// - Parameter frame: The local NV12 or BGRA frame to copy.
    ///
    /// - Returns: The pixel buffer filled with current frame data.
    ///
    /// - Throws: An error on buffer pool creation or frame data copy failure.
    func makeLocalPreviewPixelBuffer(
        _ frame: VideoFrame
    ) throws -> CVPixelBuffer {
        let pixelFormat: OSType
        switch frame.format.pixelFormat {
        case .nv12: pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .bgra: pixelFormat = kCVPixelFormatType_32BGRA
        default: throw Self.invalidImageFrameError
        }
        if localPreviewFormat != frame.format || localPreviewPixelBufferPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: frame.format.width,
                kCVPixelBufferHeightKey as String: frame.format.height,
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
            ]
            var pool: CVPixelBufferPool?
            guard
                CVPixelBufferPoolCreate(
                    kCFAllocatorDefault,
                    nil,
                    attributes as CFDictionary,
                    &pool
                )
                    == kCVReturnSuccess,
                let pool
            else {
                throw Self.invalidImageFrameError
            }
            localPreviewPixelBufferPool = pool
            localPreviewFormat = frame.format
            localPreviewFormatDescription = nil
        }

        if frame.format.pixelFormat == .bgra {
            return try Self.makeBGRAPixelBuffer(
                frame,
                pool: localPreviewPixelBufferPool
            )
        }
        return try Self.makeNV12PixelBuffer(
            frame,
            pool: localPreviewPixelBufferPool
        )
    }

    /// Reuses or creates a video format description matching the pixel buffer.
    ///
    /// - Parameter pixelBuffer: The current preview pixel buffer.
    ///
    /// - Returns: The description matching buffer dimensions and format.
    ///
    /// - Throws: An error if video format description creation fails.
    func localPreviewDescription(
        for pixelBuffer: CVPixelBuffer
    ) throws -> CMVideoFormatDescription {
        if let description = localPreviewFormatDescription,
            CMVideoFormatDescriptionMatchesImageBuffer(
                description,
                imageBuffer: pixelBuffer
            )
        {
            return description
        }

        var description: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &description
            ) == noErr, let description
        else {
            throw Self.invalidImageFrameError
        }
        localPreviewFormatDescription = description
        return description
    }

    /// Copies BGRA pixels into a displayable buffer.
    ///
    /// - Parameters:
    ///   - frame: The single-plane BGRA frame.
    ///   - pool: A matching buffer pool, or `nil` for standalone allocation.
    ///
    /// - Returns: An IOSurface buffer owning the frame's pixels.
    ///
    /// - Throws: An error if frame layout is invalid or allocation or copying fails.
    static func makeBGRAPixelBuffer(
        _ frame: VideoFrame,
        pool: CVPixelBufferPool? = nil
    ) throws -> CVPixelBuffer {
        let width = frame.format.width
        let height = frame.format.height
        let (rowBytes, overflow) = width.multipliedReportingOverflow(by: 4)
        guard frame.format.pixelFormat == .bgra, width > 0, height > 0,
            !overflow, frame.planes.count == 1
        else {
            throw invalidImageFrameError
        }

        var buffer: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &buffer
            )
        } else {
            status = CVPixelBufferCreate(
                nil,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &buffer
            )
        }

        guard status == kCVReturnSuccess, let buffer,
            CVPixelBufferGetWidth(buffer) == width,
            CVPixelBufferGetHeight(buffer) == height,
            CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
            CVPixelBufferLockBaseAddress(
                buffer,
                []
            ) == kCVReturnSuccess
        else {
            throw invalidImageFrameError
        }
        defer {
            CVPixelBufferUnlockBaseAddress(
                buffer,
                []
            )
        }

        try copyPlane(
            frame.planes[0],
            rowByteCount: rowBytes,
            rowCount: height,
            destination: CVPixelBufferGetBaseAddress(buffer),
            destinationStride: CVPixelBufferGetBytesPerRow(buffer)
        )
        return buffer
    }

    /// Validates and copies an NV12 frame into an IOSurface pixel buffer.
    ///
    /// - Parameters:
    ///   - frame: The NV12 frame to copy.
    ///   - pool: The reusable pixel buffer pool; `nil` allocates independently.
    ///
    /// - Returns: The pixel buffer containing luma and chroma planes.
    ///
    /// - Throws: An error on invalid frame layout or buffer allocation, locking, or copy failure.
    static func makeNV12PixelBuffer(
        _ frame: VideoFrame,
        pool: CVPixelBufferPool? = nil
    ) throws -> CVPixelBuffer {
        let width = frame.format.width
        let height = frame.format.height
        guard frame.format.pixelFormat == .nv12,
            width > 0,
            height > 0,
            width.isMultiple(of: 2),
            height.isMultiple(of: 2),
            frame.planes.count == 2
        else {
            throw invalidImageFrameError
        }

        var pixelBuffer: CVPixelBuffer?
        let attributes =
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &pixelBuffer
            )
        } else {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes,
                &pixelBuffer
            )
        }
        guard status == kCVReturnSuccess, let pixelBuffer,
            CVPixelBufferGetWidth(pixelBuffer) == width,
            CVPixelBufferGetHeight(pixelBuffer) == height,
            CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            throw invalidImageFrameError
        }

        guard
            CVPixelBufferLockBaseAddress(
                pixelBuffer,
                []
            ) == kCVReturnSuccess
        else {
            throw invalidImageFrameError
        }
        defer {
            CVPixelBufferUnlockBaseAddress(
                pixelBuffer,
                []
            )
        }

        try copyPlane(
            frame.planes[0],
            rowByteCount: width,
            rowCount: height,
            destination: CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                0
            ),
            destinationStride: CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                0
            )
        )
        try copyPlane(
            frame.planes[1],
            rowByteCount: width,
            rowCount: height / 2,
            destination: CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                1
            ),
            destinationStride: CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                1
            )
        )
        return pixelBuffer
    }

    /// Copies the valid data of a pixel plane row by row.
    ///
    /// - Parameters:
    ///   - plane: The plane supplying source data and row stride.
    ///   - rowByteCount: The byte count to copy per row.
    ///   - rowCount: The number of rows to copy.
    ///   - destination: The destination plane base address.
    ///   - destinationStride: The destination plane byte count per row.
    ///
    /// - Throws: An error if source data or destination layout cannot accommodate the specified region.
    static func copyPlane(
        _ plane: VideoFramePlane,
        rowByteCount: Int,
        rowCount: Int,
        destination: UnsafeMutableRawPointer?,
        destinationStride: Int
    ) throws {
        let (sourceLength, sourceLengthOverflow) = plane.stride
            .multipliedReportingOverflow(by: rowCount)
        guard let destination,
            rowByteCount > 0,
            rowCount > 0,
            plane.stride >= rowByteCount,
            destinationStride >= rowByteCount,
            !sourceLengthOverflow,
            plane.byteLength >= sourceLength,
            plane.byteOffset <= plane.data.count - sourceLength
        else {
            throw invalidImageFrameError
        }

        plane.data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            let sourceStart = source.advanced(by: plane.byteOffset)
            if plane.stride == rowByteCount, destinationStride == rowByteCount {
                memcpy(
                    destination,
                    sourceStart,
                    sourceLength
                )
                return
            }
            for row in 0..<rowCount {
                memcpy(
                    destination.advanced(by: row * destinationStride),
                    sourceStart.advanced(by: row * plane.stride),
                    rowByteCount
                )
            }
        }
    }

    /// The error describing unsupported image preview pixels.
    static var invalidImageFrameError: XmaxError {
        XmaxError(
            code: .mediaError,
            message: "Video preview frame is invalid"
        )
    }
}

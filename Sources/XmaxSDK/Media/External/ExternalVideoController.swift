//
//  ExternalVideoController.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreGraphics
import Foundation

/// Binds caller-owned video sources to SDK track ownership, rendering, and media cleanup.
final class ExternalVideoController: ExternalVideoControlling, @unchecked Sendable {

    /// The RTC external video adapter.
    private let rtcManager: any RtcManaging

    /// The media sizing service.
    private let mediaService: any MediaServicing

    /// The demand check controlling external frame conversion and submission.
    private let requestingFrames: @Sendable () -> Bool

    /// The handler delivering video to transport.
    private let videoFrameListener: MediaVideoFrameListener

    /// The handler delivering failures to lifecycle coordination.
    private let errorListener: XmaxErrorListener

    /// The lock protecting cross-thread track access.
    private let lock = NSLock()

    /// The external source's current track.
    private var track: RealtimeVideoTrack?

    /// The frame receiver for the current external binding.
    private var sink: ExternalVideoFrameSink?

    /// The bound source, with its lifecycle managed on the main actor.
    @MainActor private var source: (any RealtimeExternalVideoSource)?

    /// Creates an external input controller without acquiring capture resources.
    init(
        rtcManager: any RtcManaging,
        mediaService: any MediaServicing,
        requestingFrames: @escaping @Sendable () -> Bool,
        videoFrameListener: @escaping MediaVideoFrameListener,
        errorListener: @escaping XmaxErrorListener
    ) {
        self.rtcManager = rtcManager
        self.mediaService = mediaService
        self.requestingFrames = requestingFrames
        self.videoFrameListener = videoFrameListener
        self.errorListener = errorListener
    }

    /// The active external video track.
    var currentTrack: RealtimeVideoTrack? {
        lock.withLock { track }
    }

    /// Resolves the requested format and binds a fresh sink, rolling back partial startup on failure.
    @MainActor
    func create(
        source: any RealtimeExternalVideoSource,
        videoFormat: RealtimeVideoFormat?
    ) async throws -> RealtimeMediaStream {
        guard self.source == nil else {
            throw XmaxError(
                code: .invalidConfiguration,
                message: "Stop the current external video stream before creating another one"
            )
        }
        let original = source.videoFormat
        let requested =
            videoFormat
            ?? RealtimeVideoFormat(
                width: original.width,
                height: original.height,
                fps: mediaService.model.defaultFrameRate,
                minimumBitrate: original.minimumBitrate,
                maximumBitrate: original.maximumBitrate,
                encoderPreference: original.encoderPreference
            )
        try requested.validate()
        let size = try mediaService.resolveMediaSize(
            CGSize(
                width: requested.width,
                height: requested.height
            ),
            source: .external
        )
        let format = requested.resized(
            width: Int(size.width),
            height: Int(size.height)
        )
        try format.validate()
        try Task.checkCancellation()
        let track = RealtimeVideoTrack(
            id: "external0",
            videoFormat: format
        )
        let sink = ExternalVideoFrameSink(
            videoFormat: format,
            requestingFrames: requestingFrames,
            videoFrameListener: videoFrameListener,
            errorListener: errorListener
        )
        self.source = source
        lock.withLock {
            self.track = track
            self.sink = sink
        }
        do {
            try rtcManager.useExternalVideoSource()
            VideoRenderRegistry.register(
                track,
                binding: VideoRenderBinding(
                    attachHandler: {
                        source.attachPreview(
                            to: $0,
                            contentMode: $1
                        )
                    },
                    detachHandler: { source.detachPreview(from: $0) }
                )
            )
            try await source.start(sink: sink)
            try Task.checkCancellation()
            return RealtimeMediaStream(
                id: StreamID.local.rawValue,
                videoTrack: track
            )
        } catch {
            await stop()
            if error is CancellationError || Task.isCancelled {
                throw XmaxError(
                    code: .cancelled,
                    message: "External video binding was cancelled"
                )
            }
            throw XmaxError.from(error)
        }
    }

    /// Invalidates the sink before unmounting preview and notifying the caller-owned source.
    @MainActor
    func stop() async {
        let previousSource = source
        source = nil
        let resources = lock.withLock {
            let result = (track, sink)
            track = nil
            sink = nil
            return result
        }
        resources.1?.invalidate()
        if let track = resources.0 {
            try? VideoRenderRegistry.binding(for: track)?.detach()
            VideoRenderRegistry.unregister(track)
        }
        await previousSource?.stop()
    }
}

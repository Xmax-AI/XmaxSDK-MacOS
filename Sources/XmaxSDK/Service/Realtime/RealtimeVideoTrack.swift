//
//  RealtimeVideoTrack.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// A realtime video track and its dynamic metadata.
public final class RealtimeVideoTrack: @unchecked Sendable {

    /// The video track identifier.
    public let id: String

    /// The lock protecting mutable track metadata.
    private let metadataLock = NSLock()

    /// The synchronized media format and camera device.
    private var metadata: Metadata

    /// The video format currently used by the track.
    public var videoFormat: RealtimeVideoFormat? {
        metadataLock.withLock { metadata.videoFormat }
    }

    /// The camera position currently used by the local camera track.
    public var position: CameraPosition? {
        metadataLock.withLock { metadata.device?.position }
    }

    /// The current camera device; nil for non-camera tracks.
    public var device: CameraDevice? {
        metadataLock.withLock { metadata.device }
    }

    /// Creates a video track with the specified identity and initial metadata.
    ///
    /// - Parameters:
    ///   - id: The unique track identifier.
    ///   - videoFormat: The initial video format; `nil` if not yet known.
    ///   - device: The selected camera; `nil` for non-camera tracks.
    init(
        id: String,
        videoFormat: RealtimeVideoFormat? = nil,
        device: CameraDevice? = nil
    ) {
        self.id = id
        metadata = Metadata(
            videoFormat: videoFormat,
            device: device
        )
    }

    /// Updates device metadata while retaining video track identity.
    ///
    /// - Parameter device: The camera device after switching completes.
    func updateDevice(
        _ device: CameraDevice
    ) {
        metadataLock.withLock {
            metadata.device = device
        }
    }

    /// Updates the video track's current format.
    ///
    /// - Parameter videoFormat: The new dimensions, frame rate, and encoding configuration.
    func updateVideoFormat(
        _ videoFormat: RealtimeVideoFormat
    ) {
        metadataLock.withLock {
            metadata.videoFormat = videoFormat
        }
    }
}

private extension RealtimeVideoTrack {

    /// Stores the current video format and camera device.
    struct Metadata {

        /// The resolved media dimensions, frame rate, and encoding settings.
        var videoFormat: RealtimeVideoFormat?

        /// The selected macOS camera metadata for the local track.
        var device: CameraDevice?
    }
}

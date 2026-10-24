//
//  MediaFileMetadataManager.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Reads local media file metadata with AVFoundation.
final class MediaFileMetadataManager: MediaFileMetadataManaging, Sendable {

    /// Reads original video dimensions, display rotation, duration, and audio track information.
    ///
    /// - Parameter fileURL: The readable local video file URL.
    ///
    /// - Returns: The metadata used to prepare a local video stream.
    ///
    /// - Throws: An error if the file is unreadable, lacks video tracks, or has invalid metadata.
    func readMetadata(
        fileURL: URL
    ) async throws -> MediaFileMetadata {
        guard fileURL.isFileURL,
            FileManager.default.fileExists(atPath: fileURL.path)
        else {
            throw Self.mediaError("Media file does not exist")
        }

        let asset = AVURLAsset(url: fileURL)
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw Self.mediaError(
                    "The media file does not contain a video track"
                )
            }
            async let naturalSize = videoTrack.load(.naturalSize)
            async let preferredTransform = videoTrack.load(
                .preferredTransform
            )
            async let duration = asset.load(.duration)
            async let audioTracks = asset.loadTracks(withMediaType: .audio)

            let resolvedSize = try await naturalSize
            let resolvedTransform = try await preferredTransform
            let resolvedDuration = try await duration
            let resolvedAudioTracks = try await audioTracks
            let width = Int(abs(resolvedSize.width).rounded())
            let height = Int(abs(resolvedSize.height).rounded())
            let durationSeconds = resolvedDuration.seconds

            guard width > 0,
                height > 0,
                durationSeconds.isFinite,
                durationSeconds > 0,
                durationSeconds <= Double(Int64.max) / 1_000_000
            else {
                throw Self.mediaError("Media file metadata is invalid")
            }

            return MediaFileMetadata(
                width: width,
                height: height,
                rotation: Self.rotation(from: resolvedTransform),
                durationSeconds: durationSeconds,
                hasAudio: !resolvedAudioTracks.isEmpty
            )
        } catch let error as XmaxError {
            throw error
        } catch {
            throw Self.mediaError(
                "Failed to read media metadata: " + (error as NSError).localizedDescription
            )
        }
    }
}

private extension MediaFileMetadataManager {

    /// Converts a media track transform to the nearest quarter-turn rotation.
    ///
    /// - Parameter transform: The video track's preferred display transform.
    ///
    /// - Returns: The normalized rotation of 0, 90, 180, or 270 degrees.
    static func rotation(
        from transform: CGAffineTransform
    ) -> VideoRotation {
        let degrees = atan2(transform.b, transform.a) * 180 / .pi
        let normalized = (Int(degrees.rounded()) % 360 + 360) % 360
        let nearestQuarterTurn = ((normalized + 45) / 90 * 90) % 360
        return VideoRotation(rawValue: nearestQuarterTurn) ?? .rotation0
    }

    /// Creates a media read error.
    ///
    /// - Parameter message: A readable media error description.
    ///
    /// - Returns: A media error with the specified description.
    static func mediaError(
        _ message: String
    ) -> XmaxError {
        XmaxError(
            code: .mediaError,
            message: message
        )
    }
}

//
//  RealtimeBeautyDiagnostics.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreMedia
import CoreVideo
import Foundation

/// Exercises signed host-to-XPC processing using synthetic pixels, with no capture or network room.
@_spi(Diagnostics) public enum RealtimeBeautyDiagnostics {

    /// Verifies pixel changes, timing, retained buffer ownership, and coexistence with the RTC engine.
    ///
    /// - Returns: A JSON report suitable for a host's command-line release verification.
    ///
    /// - Throws: An error if the helper, pixels, timing, or resource isolation cannot be verified.
    @MainActor
    public static func verify() async throws -> Data {
        guard let rtc = AgoraRtcPlatform.create(appID: RtcEngineManager.defaultAppID) as? AgoraRtcPlatform else {
            throw XmaxError(code: .rtcError, message: "Unable to initialize the primary RTC engine")
        }
        defer { AgoraRtcPlatform.destroyEngine() }
        let options = RealtimeVideoBeautyOptions(smoothness: 1, lightening: 1, sharpness: 0, redness: 0)
        let processor = try await OfflineBeautyProcessor.make(options)
        do {
            let input = try makeFrame()
            let bright = try await processor.process(input)
            let brightValue = luminance(bright.pixelBuffer)
            try await processor.update(RealtimeVideoBeautyOptions(smoothness: 0, lightening: 0, sharpness: 0, redness: 0))
            let neutral = try await processor.process(input)
            let neutralValue = luminance(neutral.pixelBuffer)
            try await processor.update(options)
            let start = ContinuousClock.now
            for _ in 0..<24 {
                let output = try await processor.process(neutral)
                guard output.presentationTimeStamp == input.presentationTimeStamp,
                    output.duration == input.duration,
                    CVPixelBufferGetWidth(output.pixelBuffer) == 320,
                    CVPixelBufferGetHeight(output.pixelBuffer) == 240 else {
                    throw XmaxError(code: .mediaError, message: "Beauty changed frame timing or dimensions")
                }
            }
            let elapsed = start.duration(to: .now)
            let helperPID = await (processor as? OfflineBeautyProcessor)?.diagnosticProcessIdentifier() ?? 0
            await processor.close()
            guard helperPID > 0, helperPID != getpid(), brightValue > neutralValue + 5,
                luminance(bright.pixelBuffer) == brightValue, luminance(neutral.pixelBuffer) == neutralValue,
                rtc.engine.enableLocalVideo(false) == 0 else {
                throw XmaxError(code: .mediaError, message: "Beauty pixels, shared buffer ownership, or RTC isolation failed")
            }
            return try JSONSerialization.data(withJSONObject: [
                "hostProcessID": getpid(), "helperProcessID": helperPID,
                "pixelProcessingVerified": true, "timingPreserved": true,
                "sharedBufferOwnershipVerified": true, "rtcCoexistenceVerified": true,
                "burstFrames": 24, "burstDuration": elapsed.description,
                "brightLuminance": brightValue, "neutralLuminance": neutralValue
            ], options: [.sortedKeys])
        } catch {
            await processor.close()
            throw error
        }
    }

    /// Creates an opaque skin-colored BGRA surface on a nonzero public timeline.
    private static func makeFrame() throws -> RealtimeVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer else { throw XmaxError(code: .mediaError, message: "Unable to allocate beauty diagnostic pixels") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<240 {
            for column in 0..<320 {
                let offset = row * CVPixelBufferGetBytesPerRow(pixelBuffer) + column * 4
                base[offset] = 80
                base[offset + 1] = 100
                base[offset + 2] = 130
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return RealtimeVideoFrame(pixelBuffer: pixelBuffer,
                                  presentationTimeStamp: CMTime(value: 240, timescale: 24),
                                  duration: CMTime(value: 1, timescale: 48))
    }

    /// Reads a stable luma sample from a retained NV12 result.
    private static func luminance(_ pixels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        return Int(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)[1000])
    }
}

//
//  RealtimeMediaRecorder.swift
//  XLab
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import AVFoundation
import CoreImage
import XmaxSDK

/// Encodes the remote result on a private queue without blocking SDK delivery or modifying shared buffers.
final class RealtimeMediaRecorder: @unchecked Sendable {
    enum RecordingError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): message }
        }
    }

    private let queue = DispatchQueue(label: "ai.xmax.xlab.recording", qos: .userInitiated)
    private let admission = NSLock()
    private var accepting = true
    private var pendingBytes = 0
    private var pendingFrames = 0
    private let onInterruption: @Sendable (String) -> Void
    private let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("XLab-\(UUID().uuidString).mp4")

    // All encoder state below is confined to queue.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var canvas = CGRect.zero
    private var streamID: UUID?
    private var origin: CMTime?
    private var lastVideoTime: CMTime?
    private var audioEnd: CMTime?
    private var videoEnd = CMTime.zero
    private var audioFormat: (sampleRate: Int, channels: Int)?
    private var pendingAudio: [RealtimeAudioFrame] = []
    private var finishing = false
    private var interrupted = false
    private var result: Result<URL, Error>?
    private var finishWaiters: [CheckedContinuation<URL, Error>] = []

    init(onInterruption: @escaping @Sendable (String) -> Void) {
        self.onInterruption = onInterruption
    }

    /// Copies on disk, using a replacement directory so saving large clips never loads them into memory.
    static func save(_ source: URL, to destination: URL) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        let replacement = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: replacement) }
        let staged = replacement.appendingPathComponent(destination.lastPathComponent)
        try files.copyItem(at: source, to: staged)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staged)
        } else { try files.moveItem(at: staged, to: destination) }
    }

    /// Bounds retained frame memory even if encoding cannot keep pace with remote output.
    func append(_ frame: RealtimeMediaFrame) {
        let bytes: Int
        switch frame.content {
        case .audio(let audio): bytes = audio.data.count
        case .video(let video): bytes = CVPixelBufferGetDataSize(video.pixelBuffer)
        }
        admission.lock()
        guard accepting else { admission.unlock(); return }
        guard pendingFrames < 128, pendingBytes + bytes <= 64 * 1024 * 1024 else {
            accepting = false
            queue.async { self.interrupt("Recording stopped because the encoder could not keep up. Save the recorded portion.") }
            admission.unlock()
            return
        }
        pendingFrames += 1
        pendingBytes += bytes
        queue.async {
            defer {
                self.admission.lock()
                self.pendingFrames -= 1
                self.pendingBytes -= bytes
                self.admission.unlock()
            }
            guard !self.interrupted, !self.finishing else { return }
            do { try self.consume(frame) }
            catch { self.interrupt(error.localizedDescription) }
        }
        admission.unlock()
    }

    /// Rejects callbacks immediately; already accepted packets are drained before finalization.
    func stopAccepting() {
        admission.lock()
        accepting = false
        admission.unlock()
    }

    func finish() async throws -> URL {
        stopAccepting()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result { continuation.resume(with: result); return }
                self.finishWaiters.append(continuation)
                guard !self.finishing else { return }
                self.finishing = true
                self.pendingAudio.removeAll()
                guard let writer = self.writer, self.lastVideoTime != nil else {
                    self.complete(.failure(RecordingError.message("No remote video was received during recording.")))
                    return
                }
                guard writer.status == .writing else {
                    self.complete(.failure(writer.error ?? RecordingError.message("Unable to finish the recording.")))
                    return
                }
                writer.endSession(atSourceTime: max(self.videoEnd, self.audioEnd ?? .zero))
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    self.queue.async {
                        guard let writer = self.writer else { return }
                        if writer.status == .completed { self.complete(.success(self.outputURL)) }
                        else { self.complete(.failure(writer.error ?? RecordingError.message("Unable to save the recording."))) }
                    }
                }
            }
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        if case .failure = result {
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
        }
        self.result = result
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume(with: result) }
    }

    private func interrupt(_ message: String) {
        guard !interrupted, !finishing else { return }
        interrupted = true
        stopAccepting()
        onInterruption(message)
    }

    private func consume(_ frame: RealtimeMediaFrame) throws {
        guard frame.presentationTimeStamp.isNumeric else { return }
        if let streamID, streamID != frame.streamID {
            interrupt("The remote stream changed. Save this recording and start a new one.")
            return
        }
        streamID = frame.streamID
        switch frame.content {
        case .video(let video):
            if origin == nil { try prepare(video) }
            try appendVideo(video)
            guard !interrupted else { return }
            let buffered = pendingAudio
            pendingAudio.removeAll()
            for audio in buffered { try appendAudio(audio) }
        case .audio(let audio):
            if origin != nil { try appendAudio(audio) }
            else {
                // Video processing may lag audio delivery. Retain only a bounded recent prefix.
                pendingAudio.append(audio)
                while pendingAudio.count > 100 || pendingAudio.reduce(0, { $0 + $1.data.count }) > 2 * 1024 * 1024 {
                    pendingAudio.removeFirst()
                }
            }
        }
    }

    private func prepare(_ frame: RealtimeVideoFrame) throws {
        let width = max(2, CVPixelBufferGetWidth(frame.pixelBuffer) / 2 * 2)
        let height = max(2, CVPixelBufferGetHeight(frame.pixelBuffer) / 2 * 2)
        canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        self.writer = writer
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(20_000_000, max(2_000_000, width * height * 6)),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ])
        video.expectsMediaDataInRealTime = true
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else {
            throw RecordingError.message("This Mac cannot encode the recording's audio or video format.")
        }
        writer.add(video)
        writer.add(audio)
        videoInput = video
        audioInput = audio
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.message("Unable to start recording.")
        }
        // Both tracks use the first video PTS as their single origin; never zero tracks independently.
        origin = frame.presentationTimeStamp
        writer.startSession(atSourceTime: .zero)
    }

    private func appendVideo(_ frame: RealtimeVideoFrame) throws {
        guard let origin, let videoInput, let adaptor else { return }
        let time = frame.presentationTimeStamp - origin
        if let lastVideoTime, time < lastVideoTime {
            interrupt("The remote video clock restarted. Save this recording and start a new one.")
            return
        }
        guard time >= .zero, lastVideoTime != time else { return }
        try waitUntilReady(videoInput)
        guard let pool = adaptor.pixelBufferPool else { throw RecordingError.message("Unable to allocate recording video buffers.") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw RecordingError.message("Unable to allocate a recording video frame.")
        }
        // Keep a fixed output canvas when adaptive quality changes the incoming dimensions.
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let scale = min(canvas.width / image.extent.width, canvas.height / image.extent.height)
        let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (canvas.width - image.extent.width * scale) / 2,
                                              y: (canvas.height - image.extent.height * scale) / 2))
        let background = CIImage(color: .black).cropped(to: canvas)
        context.render(fitted.composited(over: background), to: buffer, bounds: canvas, colorSpace: colorSpace)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer?.error ?? RecordingError.message("Unable to encode a video frame.")
        }
        lastVideoTime = time
        let duration = frame.duration.isNumeric && frame.duration > .zero ? frame.duration : CMTime(value: 1, timescale: 30)
        videoEnd = time + duration
    }

    private func appendAudio(_ frame: RealtimeAudioFrame) throws {
        guard let origin, let audioInput else { return }
        guard frame.sampleRate > 0, frame.sampleRate <= 192_000, (1...2).contains(frame.channels),
              frame.samplesPerChannel > 0,
              frame.samplesPerChannel <= frame.data.count / (frame.channels * 2) else { return }
        if let audioFormat, audioFormat != (frame.sampleRate, frame.channels) {
            interrupt("The remote audio format changed. Save this recording and start a new one.")
            return
        }
        let relative = frame.presentationTimeStamp - origin
        // Trim a packet spanning the video origin (or overlapping a preceding packet) at sample precision.
        let lowerBound = audioEnd ?? .zero
        let overlap = max(.zero, lowerBound - relative)
        let skip = Int(CMTimeConvertScale(overlap, timescale: Int32(frame.sampleRate), method: .roundTowardPositiveInfinity).value)
        guard skip < frame.samplesPerChannel else {
            if let audioEnd, relative + frame.duration < audioEnd - CMTime(seconds: 1, preferredTimescale: 48_000) {
                interrupt("The remote audio clock restarted. Save this recording and start a new one.")
            }
            return
        }
        audioFormat = (frame.sampleRate, frame.channels)
        let count = frame.samplesPerChannel - skip
        let bytesPerFrame = frame.channels * 2
        let data = frame.data.subdata(in: (skip * bytesPerFrame)..<(frame.samplesPerChannel * bytesPerFrame))
        let time = relative + CMTime(value: Int64(skip), timescale: Int32(frame.sampleRate))
        var description = AudioStreamBasicDescription(mSampleRate: Double(frame.sampleRate),
            mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(frame.channels), mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format))
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
            blockBufferOut: &block))
        guard let block, let format else { throw RecordingError.message("Unable to allocate recording audio buffers.") }
        try data.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: data.count))
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(frame.sampleRate)),
                                       presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample))
        try waitUntilReady(audioInput)
        guard let sample, audioInput.append(sample) else {
            throw writer?.error ?? RecordingError.message("Unable to encode an audio packet.")
        }
        audioEnd = time + CMTime(value: Int64(count), timescale: Int32(frame.sampleRate))
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw RecordingError.message("Unable to prepare recording audio (\(status)).")
        }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput) throws {
        // Only the private encoder queue waits; the bounded SDK callback remains nonblocking.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while !input.isReadyForMoreMediaData, writer?.status == .writing,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard input.isReadyForMoreMediaData else {
            throw writer?.error ?? RecordingError.message("Recording stopped because the encoder could not keep up. Save the recorded portion.")
        }
    }
}

import AVFoundation
import XCTest
@testable import XLabRecording
@testable import XmaxSDK

final class RealtimeMediaRecorderTests: XCTestCase, @unchecked Sendable {
    private func video(_ time: Double, stream: UUID, width: Int = 160, height: Int = 90,
                       coloredQuadrants: Bool = false, mirrorSource: Bool = false) throws -> RealtimeMediaFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
        if coloredQuadrants, let base = CVPixelBufferGetBaseAddress(pixels) {
            // Distinct quadrants detect horizontal flips separately from vertical flips and rotations.
            let colors: [[UInt8]] = [[0, 0, 240, 255], [0, 240, 0, 255], [240, 0, 0, 255], [0, 240, 240, 255]]
            for y in 0..<height {
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixels)).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let column = x < width / 2 ? 0 : 1
                    let color = colors[(y < height / 2 ? 0 : 2) + (mirrorSource ? 1 - column : column)]
                    for channel in 0..<4 { row[x * 4 + channel] = color[channel] }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return RealtimeMediaFrame(streamID: stream, isDiscontinuous: false, content: .video(RealtimeVideoFrame(
            pixelBuffer: pixels, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48_000),
            duration: CMTime(value: 1, timescale: 30))))
    }

    private func audio(_ time: Double, stream: UUID, rate: Int = 48_000, channels: Int = 1) -> RealtimeMediaFrame {
        let samples = rate / 100
        let pcm = (0..<(samples * channels)).map { index in
            Int16(sin(Double(index / channels) * 2 * .pi * 440 / Double(rate)) * 5_000)
        }
        let data = pcm.withUnsafeBytes { Data($0) }
        return RealtimeMediaFrame(streamID: stream, isDiscontinuous: false, content: .audio(RealtimeAudioFrame(
            data: data, sampleRate: rate, channels: channels, samplesPerChannel: samples,
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48_000))))
    }

    func testRecordsAudioVideoWithSharedOriginAndChangingVideoDimensions() async throws {
        let recorder = RealtimeMediaRecorder { message in XCTFail(message) }
        let stream = UUID()
        // Audio arrives before the first processed video; the packet crossing the origin must be trimmed.
        recorder.append(audio(99.995, stream: stream))
        recorder.append(try video(100, stream: stream))
        for index in 0..<30 {
            let time = 100 + Double(index) / 30
            if index > 0 {
                recorder.append(try video(time, stream: stream, width: index > 14 ? 320 : 160,
                                          height: index > 14 ? 180 : 90))
            }
            for packet in 0..<3 { recorder.append(audio(time + 0.005 + Double(packet) * 0.01, stream: stream)) }
            try await Task.sleep(for: .milliseconds(8))
        }
        let url = try await recorder.finish()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videos.first)
        let audio = try XCTUnwrap(audios.first)
        let size = try await video.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 90))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.08)
        let videoPTS = try readTimes(asset: asset, track: video, settings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let audioPTS = try readTimes(asset: asset, track: audio, settings: [AVFormatIDKey: kAudioFormatLinearPCM])
        XCTAssertEqual(videoPTS.count, 30)
        XCTAssertEqual(try XCTUnwrap(videoPTS.first), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(audioPTS.first), 0, accuracy: 0.025)
        XCTAssertGreaterThan(audioPTS.count, 1) // Decoders may coalesce many AAC packets into one PCM buffer.
        let audible = try firstAudibleTime(asset: asset, track: audio)
        XCTAssertEqual(try XCTUnwrap(audible), 0, accuracy: 0.025)
        XCTAssertTrue(zip(videoPTS, videoPTS.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertTrue(zip(audioPTS, audioPTS.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testVideoOnlyRecordingAndRepeatedFinish() async throws {
        let recorder = RealtimeMediaRecorder { message in XCTFail(message) }
        let stream = UUID()
        recorder.append(try video(20, stream: stream))
        recorder.append(try video(20.1, stream: stream))
        async let first = recorder.finish()
        async let second = recorder.finish()
        let (url, sameURL) = try await (first, second)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url, sameURL)
        recorder.append(try video(21, stream: stream)) // A callback racing listener removal is ignored.
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.1333, accuracy: 0.02)
    }

    func testEncodedVideoPreservesCallbackDirectionWithoutMutatingSource() async throws {
        let colors: [[UInt8]] = [[0, 0, 240], [0, 240, 0], [240, 0, 0], [0, 240, 240]]
        for mirrored in [false, true] {
            let recorder = RealtimeMediaRecorder { message in XCTFail(message) }
            let stream = UUID()
            let first = try video(30, stream: stream, coloredQuadrants: true, mirrorSource: mirrored)
            let second = try video(30.1, stream: stream, width: 320, height: 180, coloredQuadrants: true, mirrorSource: mirrored)
            recorder.append(first)
            recorder.append(second)
            let url = try await recorder.finish()
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            let expected = mirrored ? [colors[1], colors[0], colors[3], colors[2]] : colors
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                let buffer = try XCTUnwrap(sample.imageBuffer)
                let actual = try quadrants(buffer)
                for (actualColor, expectedColor) in zip(actual, expected) {
                    for channel in 0..<3 {
                        // Classify the quadrant color; H.264 and color conversion are not byte-exact.
                        let message = "mirrored=\(mirrored), frame=\(count), channel=\(channel)"
                        if expectedColor[channel] > 0 {
                            XCTAssertGreaterThan(actualColor[channel], 176, message)
                        } else { XCTAssertLessThan(actualColor[channel], 64, message) }
                    }
                }
                count += 1
            }
            XCTAssertEqual(count, 2)
            XCTAssertEqual(reader.status, .completed)
            for source in [first, second] {
                guard case .video(let video) = source.content else { return XCTFail("Expected video") }
                XCTAssertEqual(try quadrants(video.pixelBuffer), expected, "Shared SDK frame must remain unchanged")
            }
        }
    }

    func testLateAudioKeepsItsOffsetInsteadOfStartingAtZero() async throws {
        let recorder = RealtimeMediaRecorder { message in XCTFail(message) }
        let stream = UUID()
        recorder.append(try video(50, stream: stream))
        recorder.append(try video(50.1, stream: stream))
        recorder.append(audio(50.2, stream: stream))
        recorder.append(audio(50.21, stream: stream))
        recorder.append(try video(50.25, stream: stream))
        let url = try await recorder.finish()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        // AVAssetReader can emit leading silence from an empty edit. Check actual decoded sound timing.
        let audible = try firstAudibleTime(asset: asset, track: track)
        XCTAssertEqual(try XCTUnwrap(audible), 0.2, accuracy: 0.025)
    }

    func testEmptyRecordingReturnsError() async {
        let recorder = RealtimeMediaRecorder { _ in }
        do { _ = try await recorder.finish(); XCTFail("Expected no-video error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No remote video")) }
    }

    func testStreamReplacementStopsAndPreservesExistingClip() async throws {
        let stopped = expectation(description: "Recording stops on stream replacement")
        let recorder = RealtimeMediaRecorder { _ in stopped.fulfill() }
        recorder.append(try video(10, stream: UUID()))
        recorder.append(try video(11, stream: UUID()))
        await fulfillment(of: [stopped], timeout: 3)
        let url = try await recorder.finish()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertLessThan(duration, 0.1)
    }

    func testSaveCreatesAndReplacesDestinationWithoutConsumingTemporaryClip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let destination = folder.appendingPathComponent("saved.mp4")
        try Data("first".utf8).write(to: source)
        try RealtimeMediaRecorder.save(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
        try Data("second".utf8).write(to: source)
        try RealtimeMediaRecorder.save(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("second".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func readTimes(asset: AVAsset, track: AVAssetTrack, settings: [String: Any]) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() { times.append(sample.presentationTimeStamp.seconds) }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
        return times
    }

    private func quadrants(_ buffer: CVPixelBuffer) throws -> [[UInt8]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        return [(width / 4, height / 4), (width * 3 / 4, height / 4),
                (width / 4, height * 3 / 4), (width * 3 / 4, height * 3 / 4)].map { x, y in
            let pixel = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4)
                .assumingMemoryBound(to: UInt8.self)
            return [pixel[0], pixel[1], pixel[2]]
        }
    }

    private func firstAudibleTime(asset: AVAsset, track: AVAssetTrack) throws -> Double? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            guard let block = sample.dataBuffer else { continue }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, noErr)
            let offset: Int? = data.withUnsafeBytes { bytes in
                (0..<(bytes.count / 2)).first { abs(Int(bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) > 500 }
            }
            if let offset { return sample.presentationTimeStamp.seconds + Double(offset) / 48_000 }
        }
        return nil
    }
}

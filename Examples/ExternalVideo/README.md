# External video integration

An application may own camera capture, decoding, or image processing and feed video to XmaxSDK. This source adapter accepts video and optional PCM audio, with SDK preview and automatic resizing.

The application owns permissions, device switching, capture, and final resource release; it may also provide an independent preview. The SDK owns frame bindings, model input validation, RTC transport, generation, and result tracks.

## Implement a source

Implement `RealtimeExternalVideoSource` on the main actor. Its required members are `videoFormat`, `start(sink:)`, and `stop()`. `hasAudio` defaults to false. SDK video views display submitted frames.

```swift
import CoreVideo
import Foundation
import XmaxSDK

@MainActor
final class CameraSource: RealtimeExternalVideoSource {
    nonisolated let videoFormat = RealtimeVideoFormat(width: 1920, height: 1080, fps: 30)
    nonisolated private let binding = FrameBinding()

    func start(sink: any RealtimeExternalFrameSink) async throws {
        binding.set(sink)
    }

    func stop() async {
        binding.set(nil)
    }

    nonisolated var requestedFormat: RealtimeVideoFormat? {
        guard let sink = binding.current, sink.isRequestingFrames else { return nil }
        return videoFormat
    }

    /// Call from the capture queue with pixels at the declared source dimensions.
    nonisolated func submit(_ pixelBuffer: CVPixelBuffer, timestampUs: Int64) {
        guard let sink = binding.current, sink.isRequestingFrames else { return }
        sink.pushVideo(pixelBuffer, timestampUs: timestampUs)
    }

    nonisolated func reportCaptureFailure(_ error: any Error) {
        binding.current?.reportError(error)
    }
}

private final class FrameBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (any RealtimeExternalFrameSink)?

    var current: (any RealtimeExternalFrameSink)? {
        lock.withLock { sink }
    }

    func set(_ sink: (any RealtimeExternalFrameSink)?) {
        lock.withLock { self.sink = sink }
    }
}
```

This adapter does not create or close a camera. The application starts its capture pipeline and supplies frames at the declared source dimensions. Create a separate adapter instance for each binding lifecycle; capture callbacks should retain the adapter for their own source rather than look up a global current source.

`start(sink:)` must return after binding. It must not wait for generation completion. If asynchronous binding fails or is cancelled, the SDK calls `stop()` to unwind partial setup. Make asynchronous setup cooperate with task cancellation.

## Bind and generate

Create the client, manager, and source on the main actor:

```swift
let client = XmaxClient(configuration: XmaxConfiguration(apiKey: apiKey))
let manager = client.createRealtimeManager(
    options: RealtimeConfiguration(model: .x2_1_1_preview_cn)
)
let source = CameraSource()
let localStream = try await manager.createExternalVideoStream(
    source: source,
    videoFormat: RealtimeVideoFormat(width: 1920, height: 1024, fps: 30)
)
```

The source's declared format describes its original display size. The explicit format selects the processing output. If omitted, the SDK retains source dimensions, frame rate, and encoding settings before resolving model limits. The SDK resolves external dimensions within 200,000–2,100,000 pixels and aligns both dimensions to multiples of four, without requiring a camera resolution bucket. Read the final processed format from `sink.videoFormat`; submit buffers at `source.videoFormat` dimensions and let the SDK resize them. The generation canvas is selected separately; differing aspect ratios use contain padding.

Binding enters `ready` without requiring a preview or input frame. Start capture callbacks before starting generation and continue supplying frames whenever requested:

```swift
let remoteStream = try await manager.startGeneration(
    localStream: localStream,
    context: RealtimeContext(prompt: "Transform the video into an anime scene")
)
```

Display `remoteStream.videoTrack` in `XmaxRealtimeVideo` or `XmaxRealtimeVideoView`. Do not wait for this call to return before feeding frames: startup waits for generated results and their first displayable frame.

## Frame contract

- Submit `CVPixelBuffer` in NV12 video range (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`, `420v`) or BGRA (`kCVPixelFormatType_32BGRA`). Full-range NV12 and other pixel formats are rejected.
- Buffer width and height must exactly match `source.videoFormat`. Source row padding is supported.
- The application applies orientation and mirroring. The SDK copies or resizes supplied pixels to the resolved processing dimensions. Keep local preview and submitted frames in the same coordinate system.
- Use a nonnegative, strictly increasing monotonic timestamp in microseconds, for example `Int64(DispatchTime.now().uptimeNanoseconds / 1_000)`. Do not use wall-clock dates or reset timestamps after seek or loop.
- Submit serially and pace output at the negotiated frame rate. Duplicate, decreasing, and negative timestamps are ignored.
- When `isRequestingFrames` is false, skip expensive conversions and SDK delivery while keeping your own preview active. It is a demand signal, not a rate limiter.
- Pixels are copied synchronously. The buffer may be reused after `pushVideo` returns; do not mutate it concurrently during submission. The SDK does not retain the caller's pixel buffer for asynchronous work.
- Unsupported dimensions or formats fail the active binding as a media error. The sink stops requesting frames and the normal SDK lifecycle cleanup runs.

Keep queues bounded: drop stale capture frames when conversion cannot keep up rather than building an unbounded backlog.

## Optional SDK-hosted preview

If the application already displays its own camera preview, leave the default preview methods unchanged. Binding the local track to an SDK view then displays no automatic camera image.

Bind the returned local track to `XmaxRealtimeVideoView` to preview the frames submitted to the SDK. Keep submitting while disconnected to maintain that preview. Your app may also retain its own independent capture preview.

These methods run on the main actor. The local track can then be displayed by `XmaxRealtimeVideo(track: localStream.videoTrack)`, and the SDK forwards its binding to your preview methods.

## Disconnect, unbind, and errors

| Operation | SDK behavior | Application responsibility |
| --- | --- | --- |
| `disconnect()` | Ends generation and the connection, retaining the source binding | Keep capture and preview as needed; frames remain accepted for SDK preview |
| Start generation again | Reuses the bound local stream | Keep capture callbacks ready to supply frames |
| `disconnect()` then `stopExternalVideoStream()` | Invalidates the sink, removes preview bindings, calls `source.stop()`, releases SDK media resources | Decide whether capture continues; the old local stream is no longer valid |
| `close()` | Cancels in-flight work, disconnects, and unbinds external input | Await cleanup, then release caller-owned capture and preview resources |

Report unrecoverable capture or conversion failures with `sink.reportError(error)`. Old sinks ignore frames and errors after unbinding. Planned device switches and normal page exits are not media failures.

Switch caller-owned cameras in the application and keep output matching the same sink format. To change the bound format or replace the source, disconnect, stop the external stream, and create a new one. Live source replacement is not supported. External sources may declare `hasAudio = true` and send linear PCM sample buffers with `sink.pushAudio(_:)`; the SDK converts to 48 kHz mono PCM16 without local playback.

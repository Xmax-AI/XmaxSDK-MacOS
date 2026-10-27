# Usage guide

Start with the [Quick Start](../README.md#quick-start) for camera capture and
AppKit rendering. Unless stated otherwise, these snippets reuse its `client`,
`realtime`, `localStream`, and `resultView`. Supply your own file URLs, retain
resources for the screen's lifetime, and run UI operations on the main actor.

- [Camera selection and microphone](#camera-selection-and-microphone)
- [Video format and encoding](#video-format-and-encoding)
- [External video input](#external-video-input)
- [Reference images](#reference-images)
- [Update generation conditions](#update-generation-conditions)
- [AppKit and SwiftUI](#appkit-and-swiftui)
- [Remote audio volume](#remote-audio-volume)
- [Lifecycle and errors](#lifecycle-and-errors)
- [Remote audio and video output](#remote-audio-and-video-output)
- [Manual and automatic quality](#manual-and-automatic-quality)
- [File download progress](#file-download-progress)
- [Startup timing](#startup-timing)
- [Frame interpolation](#frame-interpolation)
- [Logging](#logging)

`XmaxConfiguration.environment` selects service endpoints for the client, independently
of the realtime model. The China environment uses the domestic endpoint; the global
environment uses `https://api.xmax.cloud/open/api/v1` for general requests and
`https://api.xmax.ai/open/api/v1` for realtime sessions.

## Camera selection and microphone

List devices without starting capture:

```swift
let devices = await realtime.listCameraDevices()
let selectedDeviceID = devices.first(where: { $0.isDefault })?.id
let localStream = try await realtime.createLocalCameraStream(
    deviceID: selectedDeviceID,
    mirror: true,
    useMicrophone: true
)
```

A nil identifier selects the system default camera. An unavailable explicit
identifier returns an error rather than silently selecting a different device.
Bind the returned track to a preview view in a window. Camera input enters `ready`
when native camera capture has started and the preview is bound. Agora renders
the local preview directly; hidden preview views do not delay capture readiness.

`mirror` defaults to `false`. Enable it to mirror both Agora's native local preview
and the encoded camera video sent for generation. The setting is retained across
camera switches, format changes, quality updates, and reconnects. It changes the
input seen by the generation service. Generated video views and media callbacks
use the returned frame direction without an additional horizontal flip.

Microphone input is disabled by default. Enabling it requests permission when the
camera stream is created; audio capture begins on connection and stops on
`disconnect()`. Reconnecting the same stream resumes microphone capture. The
microphone is not played back locally. Configure the host application's usage
messages and entitlements as described in the [installation guide](./installation.md).

To switch an existing camera stream, pass a device identifier:

```swift
if let deviceID = devices.first?.id {
    _ = try await realtime.switchCamera(to: deviceID)
}
```

During active generation, camera switching stops generation, changes the device,
and resumes generation with cached conditions while retaining the RTC connection.
Camera switching is unavailable during connection or generation startup. Removing
an active camera reports a media failure and cleans up the current lifecycle;
re-enumerate devices before starting another stream.

## Video format and encoding

Current models accept `1920 × 1024` or `1024 × 1920` camera input, with a default landscape
format at 30 fps. Pass a supported format to configure upload encoding:

```swift
let format = RealtimeVideoFormat(
    width: 1920,
    height: 1024,
    fps: 30,
    minimumBitrate: 100,
    maximumBitrate: 3000,
    encoderPreference: .maintainFramerate
)
let localStream = try await realtime.createLocalCameraStream(
    videoFormat: format,
    useMicrophone: true
)
```

Use `RealtimeModel.supportedVideoFormats` to list the model's camera dimensions and
default frame rate. `resolutionBuckets` remains available for dimension-only callers.
Read `currentCameraVideoFormat` for the applied camera format; uplink quality changes
do not alter this value.

A camera stream must be `ready` and disconnected before changing its format:

```swift
await realtime.disconnect()
try await realtime.updateCameraFormat(
    RealtimeVideoFormat(width: 1024, height: 1920, fps: 24)
)
```

The existing track, selected device, and preview binding are retained. A configuration
failure leaves the preceding format in place when capture can be restored. If native
capture restoration also fails, the SDK reports a runtime media failure and releases
unusable media. Disconnect before changing dimensions or frame rate; encoding quality
controls remain available during generation.

`createLocalCameraStream(preset:deviceID:mirror:useMicrophone:)` creates a camera stream using
the preset's dimensions and the selected model's recommended frame rate. Unsupported
presets are rejected before capture starts.

`updateCameraFormat(_ preset: RealtimeCameraPreset)` changes dimensions while retaining
frame rate and bitrate settings. Both preset APIs require model support. The current
models' two camera dimensions do not match the shared presets, so `currentCameraPreset`
is nil and those presets are rejected; use an explicit supported format instead.
Camera format queries return nil for external video input.

Bitrates are in kbps. The default encoder minimum is 500 kbps, capped by the
resolved maximum; an explicit 0 removes the minimum.
Omitting the maximum uses the SDK estimate for the final upload dimensions and
frame rate. The default encoder preference is `.maintainFramerate`; `.auto` balances
frame rate and resolution, while `.maintainQuality` prioritizes resolution.
Invalid dimensions, frame rates, or bitrate bounds throw an `XmaxError`.

Upload format, server generation size, and downlink return size are distinct.
Uplink tiers use dimension scales of 1, 0.9, 0.75, 0.6, and 0.5. Dimensions stay
aligned to four pixels and retain at least 200,000 pixels when the media baseline
meets that minimum; downlink dimensions do not share this minimum.
Network quality adaptation and frame interpolation may change the return size
without changing your local preview layout.

## External video input

Use `createExternalVideoStream(source:)` instead of creating a camera stream when
your app owns capture, decoding, or processing. Only one local source may be active.

The source owns permissions, device switching, playback, and final resource release.
Submit upright `420v` NV12 or `32BGRA` buffers at `source.videoFormat` dimensions.
XmaxSDK copies and resizes them to the format reported by `sink.videoFormat`, within
200,000–2,100,000 pixels and four-pixel alignment. Camera resolution buckets do not
apply. The source frame rate and encoding settings are preserved. The overload with
`videoFormat` can request a different processing format.

Use `pushVideo(_:timestamp:)` with a nonnegative, strictly increasing monotonic
`CMTime`. The microsecond `timestampUs` convenience remains available. Keep audio
and video on the same timeline across playback loops and seeks. Apply orientation
and mirroring before submission; buffers can be reused after the call returns.

Binding enters `ready` without waiting for a frame or preview. Frames remain accepted
while disconnected, driving the SDK preview through `XmaxRealtimeVideoView`. Pace frames at
the declared source frame rate; `isRequestingFrames` becomes false after failure or
unbinding. SDK preview does not transfer ownership of capture resources.

For audio, declare `hasAudio = true` before binding and submit ready linear PCM
`CMSampleBuffer` values through `sink.pushAudio(_:)`. XmaxSDK copies and converts
samples to 48 kHz mono PCM16 in 10 ms packets. Keep the PCM format fixed for the
binding. Audio is uploaded only while published, without local playback, microphone
permission requests, or a queue for reconnection. Invalid timestamps and overlapping
buffers are ignored; gaps begin a new segment without inserted silence.

## Reference images

`RealtimeContext.referencePath` accepts a remote image URL. Upload local image
files before using them as generation conditions:

```swift
let storage = try client.createStorageManager()
let uploaded = try await storage.uploadImage(
    at: imageFileURL,
    contentType: "image/jpeg"
)
let remoteStream = try await realtime.startGeneration(
    localStream: localStream,
    context: RealtimeContext(
        prompt: "视频中角色替换成参考图中角色",
        referencePath: uploaded.url.absoluteString
    )
)
resultView.track = remoteStream.videoTrack
```

Start generation after the input is `ready`. The storage manager obtains temporary
credentials from Xmax; do not embed Tencent Cloud credentials in the application.
Already-hosted reference images can be supplied directly without uploading again.
Reference images do not replace the local video input. Built-in static-image and
file-video inputs are not exposed by this macOS version.

## Update generation conditions

During generation, send a new context without recreating the stream. A newer call
replaces an unfinished generation request and waits for its cleanup. The replaced
call throws cancellation. An established connection is retained; an incomplete
connection is released before retrying. Disconnecting or closing cancels pending
requests without starting them afterward:

```swift
try await realtime.startGeneration(
    context: RealtimeContext(prompt: "Transform the scene into an oil painting")
)
```

Starting generation caches its context and face restoration setting only after the first
processed result frame and remote audio activation succeed. A failed or cancelled start
retains the last successful context; pass `context: nil` to reuse it. If no generation has
succeeded yet, provide a context for the next attempt. Condition updates commit their
cache after signaling and validity checks complete.

To retain a reference image, include its URL in the new context. For virtual
try-on, pass `faceRestoration: true` to preserve the original face. This setting
is sent on each call; pass it again on subsequent updates when needed.

## AppKit and SwiftUI

| Purpose | AppKit | SwiftUI |
| --- | --- | --- |
| One local or remote track | `XmaxRealtimeVideoView` | `XmaxRealtimeVideo` |
| Stacked local preview and generated result | `XmaxRealtimeDualVideoView` | `XmaxRealtimeDualVideo` |

For side-by-side AppKit rendering, use two `XmaxRealtimeVideoView` instances and
assign the local and remote tracks separately.
For SwiftUI, keep both tracks in observable state and use two `XmaxRealtimeVideo` views in
an `HStack`. Clear the remote track when the remote session ends.

For a shared surface, use `XmaxRealtimeDualVideoView` in AppKit or
`XmaxRealtimeDualVideo` in SwiftUI. These stack both views in the same bounds,
retain local preview beneath generated output, reveal the result after its first
frame, and restore local preview when `remoteTrack` is nil. All four types accept
`isInteractionEnabled` during initialization.

Only the Dual types expose `remoteVideoFadeInDuration`, in seconds. The default is
`0.3`: remote video fades in after its first frame while local preview stays below
it. Set it to `0` to switch immediately; negative and nonfinite values also disable
the animation. A new value applies to the next fade-in. Clearing `remoteTrack`
cancels any fade-in and immediately reveals local preview.

See the [AppKit screen](../Examples/XLab/XLab/RealtimeViewController.swift) and
[session controller](../Examples/XLab/XLab/RealtimeSessionController.swift).

In XLab, click **Record** during generation to record the remote result's video and
audio, then click **Stop Recording** to choose where to save the MP4 (H.264/AAC).
Playback mute does not mute the recording. Ending the session or disconnecting
also finishes the current clip and opens the save panel. Canceling the panel
discards the temporary clip. XLab creates its camera stream with `mirror: true`
and records remote frame pixels as received. The result preview and recording
apply no additional mirror transform.
The macOS views support primary-button dragging for trajectory interaction during generation.

## Remote audio volume

Remote audio starts muted for camera and external video streams. Set the desired
volume after creating the local stream:

```swift
try await realtime.setRemoteAudioVolume(0.5)
let volume = await realtime.remoteAudioVolume
```

Volume is in `0...1`. This controls generated audio playback, not microphone input
or video submission. Starting generation, reconnecting the same stream, and
switching cameras preserve the current volume.

## Lifecycle and errors

Keep one manager for the generation screen and cancel screen-owned work on exit.

| Method | Effect |
| --- | --- |
| `disconnect()` | Ends generation and the remote session, retaining camera preview or the external source binding. |
| `close()` | Ends the workflow, stops SDK capture, unbinds external input, and releases RTC resources. |
| `stopLocalCameraStream()` | Stops SDK camera capture after disconnection. |
| `stopExternalVideoStream()` | Unbinds external input after disconnection; capture remains caller-owned. |

When leaving the screen, call `close()` directly. Removing views only detaches
rendering. For external input, release your own camera or decoder when your
application no longer needs it.

Register a state listener before creating input or generation:

```swift
await realtime.setStateListener { state in
    print("Xmax realtime state: \(state.connectionState.rawValue)")
    if case .failure(let error) = state.reason {
        print("Xmax realtime error: \(error.code.rawValue) \(error.message)")
    }
}
```

Completion callbacks for input readiness, a standalone connection, generation startup,
and local input shutdown are delivered after the completed operation releases ownership.
You can schedule the next operation from those callbacks without adding an artificial delay.
`preparing` and `connecting` still report active work; the intermediate `connected` state
inside combined connection-and-generation startup does not end that operation.

Handle throwing async operations with `do/catch`. Workflow-ending failures appear
in `state.reason` after cleanup completes. For camera input, preview binding is
part of readiness; do not wait for `ready` before mounting the local preview.

## Remote audio and video output

Register `setRemoteMediaFrameListener` before generation to receive owned remote-user
PCM and final video after optional interpolation:

```swift
try await realtime.setRemoteMediaFrameListener { event in
    switch event.content {
    case .audio(let audio):
        // Forward audio.data and audio.presentationTimeStamp to your recording pipeline.
        break
    case .video(let video):
        // Forward video.pixelBuffer and video.presentationTimeStamp to the same pipeline.
        break
    }
}
```

Both tracks share `streamID` and the receiver rendering timeline. Events arrive in
delivery order, rather than cross-track PTS order. Schedule or record by PTS using
one origin. `isDiscontinuous` marks the first event, clock or format changes, and
queue loss. Treat video pixel buffers as read-only. PCM belongs to the result user
before remote-user mixing; registering output does not change playback volume or
subscriptions.

Callbacks run on a dedicated serial background queue. Forward packets promptly:
pending output is limited to 256 packets and 32 MiB. Removal or replacement discards
queued output; a callback already executing may finish. Clear the listener with
`try await realtime.setRemoteMediaFrameListener(nil)`.

For video-only processing, select `.video` events from the same listener:

```swift
try await realtime.setRemoteMediaFrameListener { event in
    guard case .video(let video) = event.content else { return }
    // Forward video.pixelBuffer and video.presentationTimeStamp to your pipeline.
}
```

## Manual and automatic quality

`RealtimeQualityLevel` exposes L1 through L5. Query `uplinkQualityLevel` and
`downlinkQualityLevel` after connection; both are nil before connection or during
disconnection. Change either direction while generating:

```swift
try await realtime.setUplinkQualityLevel(.l3)
try await realtime.setDownlinkQualityLevel(.l2)
```

Uplink changes encoding dimensions without changing the capture baseline or
generation canvas. Downlink changes signal new return dimensions while retaining
interpolation limits. The reported level changes only after successful configuration;
the server may deliver the new dimensions later. Manual choices do not lock a level
against subsequent automatic adaptation.

Automatic adaptation is enabled by default. Set `isAdaptiveQualityEnabled: false`
when creating `RealtimeConfiguration` to start every connection at L1 and disable
automatic changes. Manual controls remain available and do not overwrite adaptive
history in that mode.

## Trajectory signaling

Trajectory coordinates and aspect-fit margins use the resolved local media dimensions
captured for the remote track. Changes to return dimensions, quality, or interpolation
do not change that reference or cancel an active pointer gesture. Resizing the viewport,
changing presentation options, switching track bindings, or ending generation cancels it.

Unsent trajectory updates are coalesced by generation task: only the latest pending
trajectory is retained while earlier signals or rate limits delay delivery. Once a
fragmented message starts sending, all its fragments finish in order. Starting,
changing conditions, or stopping generation discards unsent trajectories before
queuing the control signal. Controls retain their order and are not coalesced.
Disconnecting closes the queue and cancels pending work.

## File download progress

`downloadImage` and `downloadVideo` use a file-backed download task and report byte
progress during transfer. An unknown content length has total byte count zero until
completion. The final callback supplies the actual completed and total byte counts,
including for an empty file. Avoid dividing by zero when displaying progress.

Downloads are staged on disk. The destination is replaced only after a successful
HTTP response and completed transfer. Cancellation and failed transfers preserve an
existing destination and remove temporary files; the whole file is not loaded into
memory. Concurrent downloads keep their progress callbacks separate.

## Startup timing

`setLaunchTimingListener` reports optional millisecond values in
`RealtimeLaunchTiming`: `sessionMs`, `rtcJoinMs`, `publishMs`, `firstFrameMs`, and
`totalMs`. Unfinished stages are nil. The four stages align with iOS performance
logs. Total time starts when generation enters the business flow and ends after the
first displayable result frame and startup completion. It includes orchestration
between stages and is measured directly rather than adding their durations.
Camera stream creation does not start a generation timing measurement.

## Frame interpolation

Frame interpolation is enabled by default and requires macOS 26 or later with
supported hardware. Initial media configuration falls back to ordinary rendering
when interpolation is unsupported. Set `isFrameInterpolationEnabled: false` in
`RealtimeConfiguration` to opt out, or change it at runtime:

```swift
try await realtime.setFrameInterpolationEnabled(true)
let enabled = await realtime.isFrameInterpolationEnabled
```

During active generation, enabling interpolation requests a return size suitable
for interpolation; disabling it restores the return size for the current downlink
quality tier. The connection remains active. Handle unsupported configurations,
conflicting operations, and signaling failures with `do/catch`.

## Logging

SDK logs are disabled by default. Enable business and performance logs when
creating the client with an API key supplied at runtime:

```swift
let configuration = XmaxConfiguration(
    apiKey: apiKey,
    loggerOptions: [.business, .performance]
)
let client = XmaxClient(configuration: configuration)
```

Logging configuration is process-wide and shared by all `XmaxClient` instances.
XLab enables all SDK log categories.

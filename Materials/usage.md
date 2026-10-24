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
- [Generated video frames](#generated-video-frames)
- [Startup timing](#startup-timing)
- [Frame interpolation](#frame-interpolation)
- [Logging](#logging)

## Camera selection and microphone

List devices without starting capture:

```swift
let devices = await realtime.listCameraDevices()
let selectedDeviceID = devices.first(where: { $0.isDefault })?.id
let localStream = try await realtime.createLocalCameraStream(
    deviceID: selectedDeviceID,
    useMicrophone: true
)
```

A nil identifier selects the system default camera. An unavailable explicit
identifier returns an error rather than silently selecting a different device.
Bind the returned track to a preview view in a window. Camera input enters `ready`
when native camera capture has started and the preview is bound. Agora renders
the local preview directly; hidden preview views do not delay capture readiness.

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
let localStream = try await realtime.createLocalCameraStream(videoFormat: format)
```

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

Use `createExternalVideoStream(source:videoFormat:)` instead of creating a camera
stream when your application owns capture or preprocessing. Only one local input
may be active at a time.

The source owns capture, permissions, preview, conversion, and final resource
release. The SDK binds a frame sink and manages RTC transport and generation. External
input dimensions are resolved within 200,000–2,100,000 pixels and aligned to four
pixels; only camera inputs must match a model resolution bucket. Convert source
frames to the dimensions requested by the sink.
Provide `420v` NV12 or `32BGRA` pixel buffers matching `sink.videoFormat`, with
strictly increasing monotonic microsecond timestamps, while
`sink.isRequestingFrames` is true. This is a demand signal, not a frame-rate limiter.

Binding completion enters `ready` without waiting for preview or the first input
frame. Start supplying frames as soon as the sink requests them, including while
generation startup is pending. The SDK synchronously copies pixels; you may reuse
the buffer after submission returns. External audio is not supported.

See the [complete external source adapter](../Examples/ExternalVideo/README.md)
for lifecycle, threading, preview hosting, and buffer ownership details.

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

To retain a reference image, include its URL in the new context. For virtual
try-on, pass `faceRestoration: true` to preserve the original face. This setting
is sent on each call; pass it again on subsequent updates when needed.

## AppKit and SwiftUI

For side-by-side AppKit rendering, use two `XmaxVideoView` instances and assign
the local and remote tracks separately, as in the [Quick Start](../README.md#quick-start).
For SwiftUI, keep both tracks in observable state and use two `XmaxVideo` views in
an `HStack`. Clear the remote track when the remote session ends.

For a single surface, use `XmaxRealtimeVideoView` in AppKit or `XmaxRealtimeVideo`
in SwiftUI. These retain local preview beneath generated output, reveal the
result after its first frame, and restore local preview when `remoteTrack` is nil.

See the [SwiftUI screen](../Examples/XLab/XLab/RealtimeView.swift) and
[session controller](../Examples/XLab/XLab/RealtimeSessionController.swift).
The macOS views do not currently expose mouse trajectory interaction.

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

Handle throwing async operations with `do/catch`. Workflow-ending failures appear
in `state.reason` after cleanup completes. For camera input, preview binding is
part of readiness; do not wait for `ready` before mounting the local preview.

## Generated video frames

Register `setRemoteVideoFrameListener` before generation to receive final video
frames after optional interpolation. The callback runs on an internal serial
background queue. Move expensive processing to your own thread-safe pipeline and
return promptly. Each frame provides `pixelBuffer`, `presentationTimeStamp`, and
`duration`. This API exposes video only, not generated audio.

Clear the listener when no longer needed:

```swift
await realtime.setRemoteVideoFrameListener(nil)
```

## Startup timing

`setLaunchTimingListener` reports optional millisecond values in
`RealtimeLaunchTiming`: `cameraMs`, `sessionMs`, `rtcJoinMs`, `publishMs`,
`firstFrameMs`, and `totalMs`. `cameraMs` measures camera preparation through capture
readiness, including permissions and RTC initialization when needed, excluding
preview binding and display. It remains available when generation starts with an
already prepared camera and is nil for external input. Unfinished stages are nil.
The four generation stages align with iOS performance
logs. Total time includes orchestration between stages and camera preparation when
using combined camera startup, excludes extra render waits, and need not equal the
sum of the stages because camera preparation and cloud connection can overlap.

## Frame interpolation

Frame interpolation is disabled by default. It requires macOS 26 or later and
supported hardware. Enable it through `RealtimeConfiguration` or the runtime setter:

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

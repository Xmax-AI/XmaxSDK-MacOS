<p align="center">
  <img src="./Materials/images/brand/xmax-sdk.png" alt="XmaxSDK — Realtime Interactive Video Generation" width="880">
</p>

<p align="center">
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-13.0%2B-007AFF" alt="macOS 13.0+"></a>
  <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-6-F05138" alt="Swift 6"></a>
  <a href="https://platform.xmaxai.com/"><img src="https://img.shields.io/badge/Realtime-AI-FF9500" alt="Realtime AI"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-4C9A2A" alt="MIT License"></a>
</p>

We introduce XmaxSDK, a native macOS SDK designed for real-time interactive video generation via Xmax models. XmaxSDK implements an end-to-end pipeline covering media acquisition, video streaming, frame-by-frame generation, and on-device rendering, enabling developers to seamlessly integrate low-latency, high-fidelity video transformations into creative applications at a much lower cost than alternative solutions.

<p align="center"><img src="./Materials/images/xlab/generation-demo.gif" alt="X-Lab realtime generation demo" width="33%" /><img src="./Materials/images/xlab/index-demo.gif" alt="X-Lab index demo" width="33%" /><img src="./Materials/images/xlab/storage-demo.gif" alt="X-Lab storage demo" width="33%" /></p>
<p align="center"><sub>iOS X-Lab demos</sub></p>

<br>

## What you can build with XmaxSDK

<table>
  <tr>
    <th width="24%" align="left">Realtime Use Case</th>
    <th width="60%" align="left">Description</th>
    <th width="16%" align="center">Demo</th>
  </tr>
  <tr>
    <td rowspan="2" width="24%" valign="middle">
      <strong>Character Swapping</strong>
    </td>
    <td width="60%" valign="middle">
      Replace anyone in your live feed with a designated avatar in real-time.
    </td>
    <td rowspan="2" width="16%" align="center" valign="middle">
      <a href="./Materials/videos/use-cases/character-swapping.mp4">
        <img src="./Materials/images/use-cases/character-swapping-poster.png" alt="Play the Character Swapping demo" width="120">
        <br>
        <sub>▶ Play demo</sub>
      </a>
    </td>
  </tr>
  <tr>
    <td width="60%" valign="middle">
      <strong>Prompt:</strong> <code>视频中角色替换成参考图中角色</code>
      <br><br>
      <strong>Reference image:</strong> Select a clear image of the desired character with a clean background.
    </td>
  </tr>
  <tr>
    <td rowspan="2" width="24%" valign="middle">
      <strong>Virtual Try-On</strong>
    </td>
    <td width="60%" valign="middle">
      Seamlessly change outfits, preserving exact body shape, natural motion, and an
      authentic fit.
    </td>
    <td rowspan="2" width="16%" align="center" valign="middle">
      <a href="./Materials/videos/use-cases/virtual-try-on.mp4">
        <img src="./Materials/images/use-cases/virtual-try-on-poster.png" alt="Play the Virtual Try-On demo" width="120">
        <br>
        <sub>▶ Play demo</sub>
      </a>
    </td>
  </tr>
  <tr>
    <td width="60%" valign="middle">
      <strong>Prompt:</strong> <code>视频中人物衣服替换成参考图中衣服</code>
      <br><br>
      <strong>Reference image:</strong> Select a clear image of the target outfit with a clean background.
    </td>
  </tr>
  <tr>
    <td rowspan="2" width="24%" valign="middle">
      <strong>Video Restyling</strong>
    </td>
    <td width="60%" valign="middle">
      Reimagine your world in any style with an immersive visual experience.
    </td>
    <td rowspan="2" width="16%" align="center" valign="middle">
      <a href="./Materials/videos/use-cases/video-restyling.mp4">
        <img src="./Materials/images/use-cases/video-restyling-poster.png" alt="Play the Video Restyling demo" width="120">
        <br>
        <sub>▶ Play demo</sub>
      </a>
    </td>
  </tr>
  <tr>
    <td width="60%" valign="middle">
      <strong>Prompt:</strong> <code>视频风格变为参考图指定的风格</code>
      <br><br>
      <strong>Reference image:</strong> Select an image that captures the artistic style you want to apply.
    </td>
  </tr>
  <tr>
    <td rowspan="2" width="24%" valign="middle">
      <strong>AI Companions</strong>
    </td>
    <td width="60%" valign="middle">
      Summon virtual characters into your live camera feed and interact with them
      through gestures.
    </td>
    <td rowspan="2" width="16%" align="center" valign="middle">
      <a href="./Materials/videos/use-cases/ai-companions.mp4">
        <img src="./Materials/images/use-cases/ai-companions-poster.png" alt="Play the AI Companions demo" width="120">
        <br>
        <sub>▶ Play demo</sub>
      </a>
    </td>
  </tr>
  <tr>
    <td width="60%" valign="middle">
      <strong>Prompt:</strong> <code>指定角色在场景中互动</code>
      <br><br>
      <strong>Reference image:</strong> Select a clear image of the virtual character you want to summon with a clean background.
    </td>
  </tr>
</table>

<br>

## Why XmaxSDK?

<table>
  <thead>
    <tr>
      <th height="104" align="center" valign="middle">
        <img src="./Materials/images/why/low-latency.svg" alt="Low latency" width="36" height="36"><br>Low latency
      </th>
      <th height="104" align="center" valign="middle">
        <img src="./Materials/images/why/low-cost.svg" alt="Cost efficiency" width="36" height="36"><br>Cost efficiency
      </th>
      <th height="104" align="center" valign="middle">
        <img src="./Materials/images/why/high-fidelity.svg" alt="High fidelity" width="36" height="36"><br>High fidelity
      </th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>End-to-end latency is measured in <img src="./Materials/images/why/latency-highlight.svg" alt="hundreds of milliseconds" width="192" height="20" align="absmiddle">, ensuring that updates to generation conditions and interaction controls are reflected instantly.</td>
      <td>Run on a <img src="./Materials/images/why/gpu-highlight.svg" alt="single RTX 5090" width="126" height="20" align="absmiddle">, reducing inference costs by orders of magnitude versus datacenter GPUs like H100.</td>
      <td>Our models support real-time generation at up to <img src="./Materials/images/why/resolution-highlight.svg" alt="1080p" width="48" height="20" align="absmiddle">, delivering production-ready, high-quality video output.</td>
    </tr>
  </tbody>
</table>

<br>

## Prerequisites

- macOS 13.0 or later
- Swift 6
- Xcode 26 or later
- An Xmax API key

> [!WARNING]
> Never commit your Xmax API key to version control. Pass it securely at
> runtime or use short-lived temporary keys issued by the Xmax API. For step-by-step
> instructions, see [Authentication](https://platform.xmaxai.com/docs/authentication).

<br>

## Installation

XmaxSDK supports [**Swift Package Manager**](#swift-package-manager),
[**CocoaPods**](#cocoapods), and [**manual integration**](#manual).

### Swift Package Manager

In Xcode, choose **File → Add Package Dependencies**, enter the repository URL,
and add the **XmaxSDK** product to your application target:

```text
https://github.com/Xmax-AI/XmaxSDK-MacOS.git
```

### CocoaPods

Add the following to your application's `Podfile`:

```ruby
source 'https://cdn.cocoapods.org/'

platform :osx, '13.0'

use_frameworks! :linkage => :static

target 'YourApp' do
  pod 'XmaxSDK',
      :git => 'https://github.com/Xmax-AI/XmaxSDK-MacOS.git',
      :tag => '1.0.1'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |configuration|
      configuration.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
```

Install the dependencies:

```bash
pod install --repo-update
```

### Manual

Download
[`XmaxSDK-1.0.1.xcframework.zip`](https://github.com/Xmax-AI/XmaxSDK-MacOS/releases/download/1.0.1/XmaxSDK-1.0.1.xcframework.zip),
then follow the [manual integration guide](./Materials/installation.md#manual-integration)
to add the required dependencies and configure your Xcode target.

<br>

## Quick Start

### Configure permissions

Add a camera usage description to your application's `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app uses the camera for real-time video input.</string>
```

Customize this message to match your application's user experience. XmaxSDK
automatically prompts for camera access when creating the video stream and throws
an `XmaxError` if permission is denied or unavailable.

For sandboxed applications, enable Camera and the required network capabilities;
add Audio Input when using the microphone. See the
[XLab entitlements](./Examples/XLab/XLab/XLab.entitlements) for the example configuration.

<br>

### Generate and display video

The following AppKit snippet creates a camera stream, starts real-time generation,
and binds the output to a video view. Run this within a `@MainActor` async context.

```swift
import AppKit
import XmaxSDK

let client = XmaxClient(
    configuration: XmaxConfiguration(apiKey: "YOUR_XMAX_API_KEY")
)

let realtime = client.createRealtimeManager(
    options: RealtimeConfiguration(model: .x2_1_1_preview_cn)
)

let localStream = try await realtime.createLocalCameraStream()

let videoView = XmaxRealtimeDualVideoView(
    localTrack: localStream.videoTrack,
    videoContentMode: .fill
)
```

Add the video view to your window and wait for the input to enter `ready`, then
start generation:

```swift
let remoteStream = try await realtime.startGeneration(
    localStream: localStream,
    context: RealtimeContext(
        prompt: "视频中角色替换成参考图中角色",
        referencePath: "https://platform.xmaxai.com/images/source/charx/chatx_image1.jpg"
    )
)

videoView.remoteTrack = remoteStream.videoTrack
```

`XmaxRealtimeDualVideoView` keeps local preview running underneath the generated
result, reveals the result after its first frame, and restores local preview when
`remoteTrack` is cleared. To display a single local or remote track, use
`XmaxRealtimeVideoView(track:)`.

<br>

### Using SwiftUI

Use `XmaxRealtimeDualVideo` as your primary SwiftUI view. Store the local and remote
tracks in observable state, updating them dynamically as streams become available:

```swift
XmaxRealtimeDualVideo(
    localTrack: localTrack,
    remoteTrack: remoteTrack,
    videoContentMode: .fill
)
```

See the [SwiftUI guide](./Materials/usage.md#appkit-and-swiftui) for state binding.
Use `XmaxRealtimeVideo(track:)` when displaying one local or remote track.

<br>

### Pointer trajectory interaction

Once generation is confirmed and a result frame is ready, drag with the primary
mouse button in the remote video to send interaction trajectories. The SDK samples
the current pointer at about 30 Hz and shows the same white-core, green-glow trail,
pulsing rings, and fading tail as the Web and iOS SDKs. Local previews do not send
trajectories.

```swift
videoView.isInteractionEnabled = true // XmaxRealtimeVideoView or XmaxRealtimeDualVideoView
videoView.isMirrored = true           // Mirrors the result; pointer coordinates keep their displayed orientation
videoView.trajectoryRenderer = nil    // Built-in effect
```

Use `isInteractionEnabled`, `isMirrored`, and `trajectoryRenderer` in the SwiftUI
`XmaxRealtimeVideo` and `XmaxRealtimeDualVideo` initializers as well. To customize visuals,
implement `TrajectoryEffectRendering` with an `NSView` and its began, moved, ended,
and reset callbacks. The SDK continues to own input collection, coordinate mapping,
and signaling independently of the renderer.

Trajectory coordinates follow the displayed video: the left edge is `x = 0` and the
right edge is `x = 1`, regardless of display mirroring. Fit-mode black bars ignore clicks. Dragging beyond the viewport clamps to the
visible video edge. Releasing the button ends sampling; Escape, focus loss,
resizing, track changes, and generation shutdown cancel the active gesture.
Trajectory effects are display overlays and are not included in frame callbacks
or virtual-camera output.

### Listen for events

After creating `realtime`, register the listeners you need before creating the
input stream or starting generation.

| Listener | Purpose |
| --- | --- |
| `setStateListener` | Observe pipeline states and termination reasons during real-time generation. |
| `setRemoteMediaFrameListener` | Receive remote PCM and processed video with shared stream identity and timestamps. |
| `setRemoteVideoFrameListener` | Receive generated video frames for recording or custom processing. |
| `setNetworkQualityListener` | Monitor uplink and downlink network quality. |
| `setPerformanceAlarmListener` | Detect device performance limitations or recovery, with a suggested video format when available. |

For example, monitor state changes and errors:

```swift
await realtime.setStateListener { state in
    print("State: \(state.connectionState.rawValue)")
    if case .failure(let error) = state.reason {
        print("Error: \(error.code.rawValue) \(error.message)")
    }
}
```

Handle errors thrown by async calls with `do/catch`. Failures that end the realtime
workflow are also available through `state.reason` after cleanup completes.

For camera input, bind the returned video track to a preview view. The SDK enters
`ready` after native camera capture has started and the preview view is bound;
observe this through `setStateListener`. Agora renders the local preview directly,
without routing local pixels through the raw video frame observer.

<br>

### Resource Cleanup

- **`disconnect()` — Stop Remote Generation**

  Stops remote generation and cancels billing while keeping the local camera stream
  and preview active. Use this when ending the online session but staying on the
  current screen. You can start a new session later using the same local stream:

  ```swift
  await realtime.disconnect()
  ```

- **`close()` — Full Teardown & Release**

  Ends the remote session, stops local media capture, and releases all engine
  resources. Use this when leaving or dismissing the generation screen:

  ```swift
  await realtime.close()
  ```

> **Note:** These methods are alternatives, not sequential steps. When exiting a
> screen, call `close()` directly—there is no need to call `disconnect()` first.

<br>

> [!TIP]
> For complete usage examples, including camera input, reference images,
> and external video input, see the [usage guide](./Materials/usage.md).

<br>

## Dependencies

- <ins><strong>Agora RTC SDK for macOS</strong></ins> enables low-latency, real-time audio and video communication.
- <ins><strong>Tencent Cloud COS SDK</strong></ins> handles media upload and download via object storage.

<br>

## Contact us

For bug reports and feature requests, please open a
[GitHub Issue](https://github.com/Xmax-AI/XmaxSDK-MacOS/issues). For integration
assistance and technical support, contact us at [sdk@xmax.ai](mailto:sdk@xmax.ai).

<br>

## License

XmaxSDK is available under the terms of the [MIT License](LICENSE).

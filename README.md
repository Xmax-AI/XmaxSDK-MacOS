<p align="center">
  <img src="./Materials/images/brand/xmax-sdk.png" alt="XmaxSDK — Realtime Interactive Video Generation" width="880">
</p>

<p align="center">
  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-13.0%2B-007AFF" alt="macOS 13.0+"></a>
  <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-6-F05138" alt="Swift 6"></a>
  <a href="https://platform.xmaxai.com/"><img src="https://img.shields.io/badge/Realtime-AI-FF9500" alt="Realtime AI"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-4C9A2A" alt="MIT License"></a>
</p>

We introduce XmaxSDK, a macOS SDK designed for real-time interactive video generation via Xmax models. XmaxSDK implements an end-to-end pipeline covering media acquisition, video streaming, frame-by-frame generation, and on-device rendering, enabling developers to seamlessly integrate low-latency, high-fidelity video transformations into creative applications at a much lower cost than alternative solutions.

<p align="center"><img src="./Materials/images/xlab/generation-demo.gif" alt="X-Lab realtime generation demo" width="33%" /><img src="./Materials/images/xlab/index-demo.gif" alt="X-Lab index demo" width="33%" /><img src="./Materials/images/xlab/storage-demo.gif" alt="X-Lab storage demo" width="33%" /></p>

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
      :tag => '1.1.0'
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
[`XmaxSDK-1.1.0.xcframework.zip`](https://github.com/Xmax-AI/XmaxSDK-MacOS/releases/download/1.1.0/XmaxSDK-1.1.0.xcframework.zip),
then follow the [manual integration guide](./Materials/installation.md#manual-integration)
to add the required dependencies and configure your Xcode target.

<br>

## Quick Start

Use your front camera to turn yourself into a character from a reference image in real time.

```swift
import XmaxSDK

// Initialize the client
let client = XmaxClient(configuration: XmaxConfiguration(
    apiKey: "<YOUR_XMAX_API_KEY>",
    environment: .global
))

// Initialize the realtime manager
let realtime = client.createRealtimeManager(
    options: RealtimeConfiguration(model: .x2_1)
)

// Create the video view
let videoView = XmaxRealtimeDualVideoView(frame: view.bounds)
view.addSubview(videoView)

// Create a camera stream and bind the preview
let localStream = try await realtime.createLocalCameraStream(
    videoFormat: RealtimeVideoFormat(width: 1920, height: 1080, fps: 30),
    deviceID: nil,
    mirror: false,
    useMicrophone: false
)
videoView.localTrack = localStream.videoTrack

// Once the preview is ready, start generation and display the result
let remoteStream = try await realtime.startGeneration(
    localStream: localStream,
    context: RealtimeContext(
        prompt: "视频中角色替换成参考图中角色",
        referencePath: "https://cdn.xmax.ai/images/playground/charx/charx_image1.png?v=26&presetVersion=20261022"
    )
)
videoView.remoteTrack = remoteStream.videoTrack

// Run the following when generation is no longer needed
await realtime.close()
```

<br>

## Credit balance

Query the remaining credits for the account owning your API key:

```swift
let balance = try await client.getCreditBalance()
print(balance.currentBalance)
```

This sends `GET /open/api/v1/balance` with `X-Api-Key` to the client's configured general API environment. Each call fetches the server balance, including fractional credits. Missing or invalid values throw `XmaxError`; they are never substituted with zero. Your app controls refresh timing, balance display, and any low-credit behavior.

XLab displays a credits pill on both the landing and session toolbars, with automatic refreshes every five seconds and after stopping a session. Balances below 300 credits appear in red. Click the pill to open the credits page; its tooltip explains loading or query failures. Changing API keys clears the previous account's balance immediately.

## Generated-result beauty

Result beauty is disabled by default. Configure it before connection or while generating:

```swift
await manager.setRemoteVideoBeautyErrorListener { error in
    // Beauty has been disabled; generation and original result output continue.
    showRecoverableError(error.message)
}
try await manager.setRemoteVideoBeauty(
    RealtimeVideoBeautyOptions(smoothness: 0.3, lightening: 0.2, sharpness: 0.2, redness: 0.1)
)
try await manager.setRemoteVideoBeauty(nil)
```

Strengths must be finite values in `0...1`. Processing runs after optional interpolation, before result preview and `setRemoteMediaFrameListener` output. Input camera pixels and upstream publication are unchanged. The processed frame retains the original PTS, duration, dimensions, and orientation. Treat callback buffers as read-only. The first implementation supports SDR BT.709, full/video-range NV12 and BGRA result buffers backed by IOSurface.

Beauty requires a private **XPC service**, isolated from the app's realtime Agora engine:

1. Add a macOS XPC Service target named `XmaxRealtimeVideoBeautyWorker`, with an app-specific bundle identifier such as `com.example.YourApp.realtime-video-beauty` and deployment target macOS 13 or later. The SDK reads the identifier from the embedded service's Info.plist; a distinct identifier gives each host its own sandbox container.
2. Link the package product `XmaxRealtimeVideoBeautyWorkerSupport` to that target. Its main entry point is:

   ```swift
   import XmaxRealtimeVideoBeautyWorkerSupport
   XmaxRealtimeVideoBeautyWorker.run()
   ```

3. Use an XPC service Info.plist with `CFBundlePackageType = XPC!`, `XPCService.ServiceType = Application`, and `XPCService.RunLoopType = dispatch_main`. Enable App Sandbox with no camera or microphone entitlement. The service owns its sandbox; do not set `com.apple.security.inherit`.
4. Embed and sign the service in `YourApp.app/Contents/XPCServices/XmaxRealtimeVideoBeautyWorker.xpc` with the app's signing team. Include the package's Agora/ClearVision dynamic frameworks. If frameworks are shared in the outer app's `Contents/Frameworks`, add `@executable_path/../../../../Frameworks` to the service's runtime search paths.

The SDK opens an app-private XPC connection and transfers IOSurface handles, with one frame request in flight per pipeline. Explicit output leases prevent native pool buffers from being reused while preview, virtual-camera output, or recording still owns them. Missing services, processing failures, and bounded-request timeouts are recoverable errors. Options survive reconnects; `close()` clears beauty options and its listener. No service is activated until beauty is requested.

The XLab example embeds this service. During a session, use **Beauty** in the toolbar to enable or disable result beauty and its overlay with four strength sliders. XLab saves the switch and strengths locally; the first run enables beauty with all four strengths at zero. Changes affect both result preview and recordings. A processing failure disables the effect and displays a recoverable message while generation continues.

## Dependencies

- <ins><strong>Agora RTC SDK</strong></ins> enables low-latency, real-time audio and video communication.
- <ins><strong>Tencent Cloud COS SDK</strong></ins> handles media upload and download via object storage.

<br>

## Contact us

For bug reports and feature requests, please open a
[GitHub Issue](https://github.com/Xmax-AI/XmaxSDK-MacOS/issues). For integration
assistance and technical support, contact us at [sdk@xmax.ai](mailto:sdk@xmax.ai).

<br>

## License

XmaxSDK is available under the terms of the [MIT License](LICENSE).

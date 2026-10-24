# Installation guide

Start with the [README installation steps](../README.md#installation). This guide
covers the native macOS package and its dependencies.

## Requirements

- macOS 13.0 or later
- Xcode 26 or later with Swift 6.2+; Swift 6 language mode
- Apple silicon (`arm64`) or Intel (`x86_64`)

## Swift Package Manager

In Xcode, add the repository through **File → Add Package Dependencies** and select
a branch or published version containing the SDK:

```text
https://github.com/Xmax-AI/XmaxSDK-MacOS.git
```

Add only the **XmaxSDK** product to your application target. For a local checkout,
choose **Add Local** and select the SDK directory instead. A package manifest can
use `.package(path: "/path/to/XmaxSDK")`.

- Agora RTC `4.6.2` resolves from the
  [official macOS package](https://github.com/AgoraIO/AgoraRtcEngine_macOS), using
  the `RtcBasic` product.
- COS `6.5.7` is packaged as Xmax-built dynamic XCFrameworks for
  `QCloudCore/WithoutMTA` and `QCloudCOSXML/Transfer`, downloaded from the
  [COS dependency release](https://github.com/Xmax-AI/XmaxSDK-MacOS/releases/tag/cos-6.5.7-spm.1).
  `Package.swift` pins each archive URL and SHA-256 checksum. These are macOS
  binaries, separate from the iOS frameworks.
- Both COS frameworks contain native macOS `arm64` and `x86_64` slices. Xcode
  handles linking, embedding, and signing the dynamic dependencies.
- Keep the bundled licenses, notices, resources, and privacy manifests when
  redistributing the frameworks. See the
  [redistribution notices](https://github.com/Xmax-AI/XmaxSDK-MacOS/releases/download/cos-6.5.7-spm.1/COS-6.5.7-NOTICES.txt).

The frameworks are built from Tencent's [unmodified 6.5.7 source](https://github.com/tencentyun/qcloud-sdk-ios/tree/6.5.7),
without optional analytics components. This is Xmax's binary packaging, not an
official Tencent Swift package. The source repository does not need to contain
the COS binaries; SwiftPM downloads and verifies the archives during dependency
resolution, following the same distribution approach as the iOS SDK.

## CocoaPods

Follow the [Podfile example](../README.md#cocoapods), then run:

```bash
pod install --repo-update
```

Open the generated `.xcworkspace`. CocoaPods builds the same `Sources/XmaxSDK`
using official Agora `4.6.2` and COS `6.5.7` dependencies; it does not link the
SwiftPM Release assets. COS declares its own `QCloudCOSXML` privacy resource
bundle in its official podspec; XmaxSDK does not add a duplicate resource bundle.

Use one package manager for the SDK and its dependencies in an application target.
Do not add the same frameworks separately through SwiftPM, CocoaPods, or manual
embedding.

## Manual integration

Once a macOS SDK binary release is available, download the SDK archive linked in
the [README](../README.md#manual) and extract `XmaxSDK.xcframework`.
Use the installation guide from the same SDK version as the downloaded archive.

### Download the dependencies

Use these pinned macOS dependencies:

- [Agora RTC 4.6.2](https://download.agora.io/sdk/release/AgoraRtcEngine_macOS-4.6.2.zip):
  `AgoraRtcKit.xcframework`, `Agorafdkaac.xcframework`, `Agoraffmpeg.xcframework`,
  `AgoraSoundTouch.xcframework`, and `video_dec.xcframework`.
- [Agora Infrastructure 1.3.5](https://download.agora.io/sdk/release/AgoraInfra_macOS-1.3.5.zip):
  `aosl.xcframework`.
- [COS macOS 6.5.7](https://github.com/Xmax-AI/XmaxSDK-MacOS/releases/tag/cos-6.5.7-spm.1):
  `QCloudCore-6.5.7.xcframework.zip` and `QCloudCOSXML-6.5.7.xcframework.zip`.
  Extract both archives and keep the framework resources and redistribution notices.

### Configure embedding

Add the frameworks to the application target under **Frameworks, Libraries, and
Embedded Content**:

| Framework | Embed setting |
| --- | --- |
| `XmaxSDK.xcframework` | Do Not Embed |
| `AgoraRtcKit.xcframework` | Embed & Sign |
| `Agorafdkaac.xcframework` | Embed & Sign |
| `Agoraffmpeg.xcframework` | Embed & Sign |
| `AgoraSoundTouch.xcframework` | Embed & Sign |
| `video_dec.xcframework` | Embed & Sign |
| `aosl.xcframework` | Embed & Sign |
| `QCloudCore.xcframework` | Embed & Sign |
| `QCloudCOSXML.xcframework` | Embed & Sign |

The SDK is static; the listed Agora and Xmax-packaged COS dependencies are dynamic.
Use macOS variants containing the architecture of your application. The SDK
archive includes both `arm64` and `x86_64` in one native macOS variant.
Retain the dependencies' licenses and privacy manifests in the application.

Set the deployment target to macOS 13.0 or later and use Swift 6 language mode.
Configure camera, microphone, and network access as described below.

## Configure the application target

Add `NSCameraUsageDescription` to your application's `Info.plist` for built-in
camera capture. Add `NSMicrophoneUsageDescription` if enabling microphone input.
The usage descriptions must describe your application's behavior.

For App Sandbox, enable **Camera**, **Outgoing Connections (Client)**, and
**Audio Input** when using a microphone. Ensure your network configuration also
permits RTC traffic; [XLab's entitlements](../Examples/XLab/XLab/XLab.entitlements)
show the example application's configuration. Configure the corresponding
resource permissions for Hardened Runtime.

If the application reads a user-selected reference image, use the appropriate
sandbox file access capability and retain access for the duration of the upload.
External video sources own their capture permissions and device lifecycle.

## Example application

Open [`Examples/XLab/XLab.xcodeproj`](../Examples/XLab/XLab.xcodeproj), select
**XLab**, and run on your Mac. It uses the local Swift package and adds Kingfisher
as an example-only dependency. Kingfisher is not required by SDK consumers.

Continue with the [Quick Start](../README.md#quick-start) or the
[usage guide](./usage.md).

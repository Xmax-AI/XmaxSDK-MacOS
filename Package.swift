// swift-tools-version: 6.2
//
//  Package.swift
//  XmaxSDK
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import PackageDescription

let package = Package(
    name: "XmaxSDK",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "XmaxSDK", targets: ["XmaxSDK"])
    ],
    dependencies: [
        .package(url: "https://github.com/AgoraIO/AgoraRtcEngine_macOS.git", exact: "4.6.2")
    ],
    targets: [
        .target(
            name: "XmaxSDK",
            dependencies: [
                .product(name: "RtcBasic", package: "AgoraRtcEngine_macOS"),
                "QCloudCore",
                "QCloudCOSXML"
            ],
            path: "Sources/XmaxSDK"
        ),
        .binaryTarget(
            name: "QCloudCore",
            url: "https://github.com/Xmax-AI/XmaxSDK-MacOS/releases/download/cos-6.5.7-spm.1/QCloudCore-6.5.7.xcframework.zip",
            checksum: "d7b2529245d872168a54dcc28037a668ac4fe90133a3d90e24327abf6c4b0d2d"
        ),
        .binaryTarget(
            name: "QCloudCOSXML",
            url: "https://github.com/Xmax-AI/XmaxSDK-MacOS/releases/download/cos-6.5.7-spm.1/QCloudCOSXML-6.5.7.xcframework.zip",
            checksum: "e655a38c6f5cfd5ab7d0c06bb18a22c5b8ed32ebbee181584ca15fab492576f0"
        ),
        .testTarget(
            name: "XmaxSDKTests",
            dependencies: ["XmaxSDK"],
            path: "Tests/XmaxSDKTests",
            // Command-line XCTest bundles load third-party dynamic frameworks from the build products directory.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        )
    ]
)

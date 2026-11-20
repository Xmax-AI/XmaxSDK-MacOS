//
//  RealtimeCamera.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The camera input used to create a local camera stream.
public enum RealtimeCamera: Equatable, Sendable {

    /// Prefers a front or rear camera, falling back to the system default when unavailable.
    case position(CameraPosition)

    /// Uses the system default camera when the stream is created.
    case systemDefault

    /// Uses the camera identifier returned by `listCameraDevices()`.
    case device(id: String)
}

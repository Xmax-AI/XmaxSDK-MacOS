//
//  AgoraRtcCameraEngine.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit

/// The native camera capture, preview, and device selection operations used by the platform adapter.
protocol AgoraRtcCameraEngine: AnyObject {

    /// Enables or disables native local video capture.
    func enableLocalVideo(
        _ enabled: Bool
    ) -> Int32

    /// Starts capture for the specified native source and camera configuration.
    func startCameraCapture(
        _ sourceType: AgoraVideoSourceType,
        config: AgoraCameraCapturerConfiguration?
    ) -> Int32

    /// Stops capture for the specified native video source.
    func stopCameraCapture(
        _ sourceType: AgoraVideoSourceType
    ) -> Int32

    /// Starts native preview for the specified video source.
    func startPreview(
        _ sourceType: AgoraVideoSourceType
    ) -> Int32

    /// Stops native preview for the specified video source.
    func stopPreview(
        _ sourceType: AgoraVideoSourceType
    ) -> Int32

    /// Binds or removes the local rendering canvas.
    func setupLocalVideo(
        _ local: AgoraRtcVideoCanvas?
    ) -> Int32

    /// Selects a native media device by its identifier.
    func setDevice(
        _ type: AgoraMediaDeviceType,
        deviceId: String
    ) -> Int32
}

extension AgoraRtcEngineKit: AgoraRtcCameraEngine {}

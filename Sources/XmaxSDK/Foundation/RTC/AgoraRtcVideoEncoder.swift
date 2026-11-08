//
//  AgoraRtcVideoEncoder.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

@preconcurrency import AgoraRtcKit

/// Applies upstream video encoding to the global engine or joined connection.
protocol AgoraRtcVideoEncoder: AnyObject {

    /// Applies upstream video encoding and mirror settings before joining a connection.
    func setVideoEncoderConfiguration(
        _ config: AgoraVideoEncoderConfiguration
    ) -> Int32

    /// Applies upstream video encoding and mirror settings to the joined connection.
    func setVideoEncoderConfigurationEx(
        _ config: AgoraVideoEncoderConfiguration,
        connection: AgoraRtcConnection
    ) -> Int32
}

extension AgoraRtcEngineKit: AgoraRtcVideoEncoder {}

//
//  RtcEventListener.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Receives RTC media and data signaling events.
protocol RtcEventListener: AnyObject {

    /// Receives remote user video publication state changes.
    ///
    /// - Parameters:
    ///   - userID: The remote RTC user identifier.
    ///   - published: Whether video is currently published.
    @MainActor
    func onRemoteVideoPublished(
        userID: String,
        published: Bool
    )

    /// Receives errors preventing the RTC connection or signaling transport from continuing.
    ///
    /// - Parameter error: The connection or signaling transport error.
    @MainActor
    func onRtcFailure(
        _ error: XmaxError
    )
}

//
//  VideoBeautyProcessing.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Processes owned result frames independently of RTC capture, publication, and room state.
protocol VideoBeautyProcessing: AnyObject, Sendable {

    /// Applies validated strengths without replacing the media graph.
    func update(
        _ options: RealtimeVideoBeautyOptions
    ) async throws

    /// Returns owned processed pixels with the original dimensions, PTS, and duration.
    /// Temporary output pressure permits retrying later frames without closing the processor.
    func process(
        _ frame: RealtimeVideoFrame
    ) async throws -> RealtimeVideoFrame

    /// Waits for in-flight work and releases the private media service.
    func close() async
}

/// Identifies a temporary output-capacity limit without invalidating the beauty graph.
enum VideoBeautyProcessingError: Error {
    /// Downstream consumers still hold every buffer in the bounded output pool.
    case outputBackpressure
}

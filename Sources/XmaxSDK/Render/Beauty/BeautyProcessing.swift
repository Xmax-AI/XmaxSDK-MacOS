//
//  BeautyProcessing.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Processes owned result frames independently of RTC capture, publication, and room state.
protocol BeautyProcessing: AnyObject, Sendable {

    /// Applies validated strengths without replacing the media graph.
    func update(
        _ options: RealtimeVideoBeautyOptions
    ) async throws

    /// Returns owned processed pixels with the original dimensions, PTS, and duration.
    /// Temporary output pressure permits retrying later frames without closing the processor.
    func process(
        _ input: BeautyFrameInput
    ) async throws -> RealtimeVideoFrame

    /// Waits for in-flight work and releases the private media service.
    func close() async
}

/// Carries output color preparation to the beauty processor.
enum BeautyFrameInput: Sendable {

    /// The frame already checked for beauty.
    case prepared(RealtimeVideoFrame)

    /// The passthrough frame and the reason beauty cannot process it.
    case unsupported(RealtimeVideoFrame, XmaxError)

    /// A raw frame that needs strict preparation before beauty.
    case unprepared(RealtimeVideoFrame)

    /// The frame delivered if beauty is disabled or fails.
    var frame: RealtimeVideoFrame {
        switch self {
        case .prepared(let frame), .unsupported(let frame, _), .unprepared(let frame):
            return frame
        }
    }

    /// Resolves compatible pixels or fails with the recorded color error.
    func resolve(
        using converter: BeautyColorConverter
    ) throws -> RealtimeVideoFrame {
        switch self {
        case .prepared(let frame):
            return frame
        case .unsupported(_, let error):
            throw error
        case .unprepared(let frame):
            return try converter.prepare(frame)
        }
    }
}

/// Identifies a temporary output-capacity limit without invalidating the beauty graph.
enum BeautyProcessingError: Error {
    /// Downstream consumers still hold every buffer in the bounded output pool.
    case outputBackpressure
}

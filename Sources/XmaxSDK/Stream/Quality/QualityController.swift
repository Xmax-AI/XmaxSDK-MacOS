//
//  QualityController.swift
//  XmaxSDK
//  Repo: https://github.com/XingMai/XmaxSDK-MacOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Converts RTC quality events for realtime generation listeners.
final class QualityController: QualityControlling, RtcQualityListener,
    @unchecked Sendable {

    /// Concurrency control
    private let listenerLock = NSLock()

    /// Event listeners
    private var networkQualityListener: RealtimeNetworkQualityListener?
    private var performanceAlarmListener: RealtimePerformanceAlarmListener?
    private var uplinkStatisticsListener: UplinkVideoStatisticsListener?
    private var downlinkStatisticsListener: DownlinkVideoStatisticsListener?

    /// Statistics lifecycle
    private var uplinkStatisticsEnabled = false
    private var downlinkStatisticsUser: String?
    private var uplinkStatisticsVersion = 0
    private var downlinkStatisticsVersion = 0

    /// Automatic quality adjustment
    private var uplinkQuality: QualityDirection?
    private var downlinkQuality: QualityDirection?
    private var history: QualityHistory?
    private var adaptiveListener: (@Sendable (RealtimeNetworkQuality, TimeInterval) -> Void)?
    private let historyDefaults: UserDefaults

    /// Creates a quality controller and registers RTC quality callbacks.
    ///
    /// - Parameters:
    ///   - rtcManager: The RTC manager providing network and media quality statistics.
    ///   - historyDefaults: The preference store retaining model-specific tier history.
    init(rtcManager: any RtcManaging, historyDefaults: UserDefaults = .standard) {
        self.historyDefaults = historyDefaults
        rtcManager.setQualityListener(self)
    }

    /// Quality configuration
    var qualityConfiguration: QualityConfiguration? {
        listenerLock.withLock { configuration() }
    }

    /// Prepares transport tiers from the media baseline and model history.
    ///
    /// - Parameters:
    ///   - baseline: The original local media output format, unchanged by tier adjustments.
    ///   - model: The model identifier isolating tier history.
    /// - Returns: The initial upstream and downstream configuration for this connection.
    func prepareQuality(baseline: RealtimeVideoFormat, model: String) -> QualityConfiguration {
        listenerLock.withLock {
            let history = QualityHistory(model: model, defaults: historyDefaults)
            self.history = history
            let minimumInputPixels = RealtimeModel(rawValue: model)?.minimumInputPixels ?? 0
            uplinkQuality = QualityDirection(baseline: baseline, level: history.read(downlink: false), downlink: false, minimumInputPixels: minimumInputPixels)
            downlinkQuality = QualityDirection(baseline: baseline, level: history.read(downlink: true), downlink: true)
            return configuration()!
        }
    }

    /// Sets the internal adaptive sample listener without replacing the caller's network listener.
    ///
    /// - Parameter listener: Receives network quality and monotonic sample time; nil removes it.
    func setAdaptiveQualityListener(_ listener: (@Sendable (RealtimeNetworkQuality, TimeInterval) -> Void)?) {
        listenerLock.withLock { adaptiveListener = listener }
    }

    /// Calculates candidate tiers from a sample without committing them early.
    ///
    /// - Parameters:
    ///   - quality: The current upstream and downstream network quality.
    ///   - sampledAt: The monotonic sample time in seconds.
    /// - Returns: The candidate tiers meeting consecutive sample and cooldown requirements.
    func proposeQuality(_ quality: RealtimeNetworkQuality, sampledAt: TimeInterval) -> QualityChange {
        listenerLock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            return QualityChange(
                uplink: uplinkQuality?.observe(quality.uplink, sampledAt: sampledAt, now: now),
                downlink: downlinkQuality?.observe(quality.downlink, sampledAt: sampledAt, now: now)
            )
        }
    }

    /// Commits one direction's outcome, saving tier history only on success.
    ///
    /// - Parameters:
    ///   - downlink: true indicates downstream; false indicates upstream.
    ///   - level: The attempted tier in 1...5.
    ///   - success: Whether configuration applied successfully.
    func completeQuality(downlink: Bool, level: Int, success: Bool) {
        listenerLock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            if downlink {
                downlinkQuality?.complete(level: level, success: success, now: now)
            } else {
                uplinkQuality?.complete(level: level, success: success, now: now)
            }
            if success { history?.write(level: level, downlink: downlink) }
        }
    }

    /// Clears consecutive samples so busy-period history cannot trigger tier changes.
    func resetQualitySamples() {
        listenerLock.withLock {
            uplinkQuality?.resetSamples()
            downlinkQuality?.resetSamples()
        }
    }

    /// Releases this connection's tier state and internal sample listener.
    func resetQuality() {
        listenerLock.withLock {
            uplinkQuality = nil
            downlinkQuality = nil
            history = nil
            adaptiveListener = nil
        }
    }

    /// Reads quality configuration after both directions are prepared.
    ///
    /// - Returns: The baseline and tiers, or `nil` before preparation completes.
    private func configuration() -> QualityConfiguration? {
        guard let uplinkQuality, let downlinkQuality else { return nil }
        return QualityConfiguration(baseline: uplinkQuality.baseline, uplinkLevel: uplinkQuality.level, downlinkLevel: downlinkQuality.level, minimumInputPixels: uplinkQuality.minimumInputPixels)
    }

    /// Sets the upstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil before publication or after disconnect. Pass nil to clear it.
    func setUplinkVideoStatisticsListener(_ listener: UplinkVideoStatisticsListener?) {
        listenerLock.withLock {
            uplinkStatisticsVersion &+= 1
            uplinkStatisticsListener = listener
        }
    }

    /// Sets the downstream video statistics listener.
    ///
    /// - Parameter listener: The main-thread callback; receives nil when the result stream is cleared. Pass nil to clear it.
    func setDownlinkVideoStatisticsListener(_ listener: DownlinkVideoStatisticsListener?) {
        listenerLock.withLock {
            downlinkStatisticsVersion &+= 1
            downlinkStatisticsListener = listener
        }
    }

    /// Sets upstream statistics reception and notifies listeners to clear old metrics.
    ///
    /// - Parameter enabled: Whether local video is published.
    func setUplinkVideoStatisticsEnabled(_ enabled: Bool) {
        let version = listenerLock.withLock {
            uplinkStatisticsVersion &+= 1
            uplinkStatisticsEnabled = enabled
            return uplinkStatisticsVersion
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let listener = listenerLock.withLock {
                uplinkStatisticsVersion == version ? uplinkStatisticsListener : nil
            }
            listener?(nil)
        }
    }

    /// Sets the downstream target user and notifies listeners to clear old metrics.
    ///
    /// - Parameter userID: The result stream user identifier; nil stops reception.
    func setDownlinkVideoStatisticsUser(_ userID: String?) {
        let version = listenerLock.withLock {
            downlinkStatisticsVersion &+= 1
            downlinkStatisticsUser = userID
            return downlinkStatisticsVersion
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let listener = listenerLock.withLock {
                downlinkStatisticsVersion == version ? downlinkStatisticsListener : nil
            }
            listener?(nil)
        }
    }

    /// Receives local upstream video statistics.
    ///
    /// - Parameter statistics: The upstream metrics for this reporting interval.
    @MainActor
    func onUplinkVideoStatistics(_ statistics: UplinkVideoStatistics) {
        let listener = listenerLock.withLock {
            uplinkStatisticsEnabled ? uplinkStatisticsListener : nil
        }
        listener?(statistics)
    }

    /// Receives remote downstream video statistics.
    ///
    /// - Parameter statistics: The downstream metrics for this reporting interval.
    @MainActor
    func onDownlinkVideoStatistics(_ statistics: DownlinkVideoStatistics) {
        let listener = listenerLock.withLock {
            statistics.userID == downlinkStatisticsUser ? downlinkStatisticsListener : nil
        }
        listener?(statistics)
    }

    /// Sets the upstream and downstream network quality listener.
    ///
    /// - Parameter listener: The main-thread network quality callback; `nil` clears it.
    func setNetworkQualityListener(
        _ listener: RealtimeNetworkQualityListener?
    ) {
        listenerLock.withLock {
            networkQualityListener = listener
        }
    }

    /// Sets the device performance alarm listener.
    ///
    /// - Parameter listener: The main-thread performance limitation or recovery callback; `nil` clears it.
    func setPerformanceAlarmListener(
        _ listener: RealtimePerformanceAlarmListener?
    ) {
        listenerLock.withLock {
            performanceAlarmListener = listener
        }
    }

    /// Receives realtime upstream and downstream network quality.
    ///
    /// - Parameters:
    ///   - uplink: The local sending network quality.
    ///   - downlink: The remote receiving network quality.
    @MainActor
    func onNetworkQuality(
        uplink: RtcQualityLevel,
        downlink: RtcQualityLevel
    ) {
        let listener = listenerLock.withLock { networkQualityListener }
        let quality = RealtimeNetworkQuality(
            uplink: Self.networkQualityLevel(uplink),
            downlink: Self.networkQualityLevel(downlink)
        )
        let adaptive = listenerLock.withLock { adaptiveListener }
        adaptive?(quality, ProcessInfo.processInfo.systemUptime)
        listener?(quality)
    }

    /// Receives performance limitation or recovery events.
    ///
    /// - Parameters:
    ///   - limited: Whether performance is currently limited.
    ///   - suggestedWidth: The suggested video width in pixels.
    ///   - suggestedHeight: The suggested video height in pixels.
    ///   - suggestedFrameRate: The suggested video frame rate in fps.
    @MainActor
    func onPerformanceAlarm(
        limited: Bool,
        suggestedWidth: Int,
        suggestedHeight: Int,
        suggestedFrameRate: Int
    ) {
        let listener = listenerLock.withLock { performanceAlarmListener }
        listener?(
            RealtimePerformanceAlarm(
                status: limited ? .limited : .recovered,
                suggestedVideoFormat: Self.suggestedVideoFormat(
                    width: suggestedWidth,
                    height: suggestedHeight,
                    frameRate: suggestedFrameRate
                )
            )
        )
    }
}

private extension QualityController {
    /// Maps RTC quality levels to public network quality levels.
    ///
    /// - Parameter level: The underlying RTC network quality level.
    /// - Returns: The corresponding public network quality level.
    static func networkQualityLevel(
        _ level: RtcQualityLevel
    ) -> RealtimeNetworkQualityLevel {
        switch level {
        case .unknown:
            .unknown
        case .excellent:
            .excellent
        case .good:
            .good
        case .poor:
            .poor
        case .bad:
            .bad
        case .veryBad:
            .veryBad
        case .down:
            .down
        }
    }

    /// Extracts a valid video format recommendation from a performance alarm.
    ///
    /// - Parameters:
    ///   - width: The suggested pixel width.
    ///   - height: The suggested pixel height.
    ///   - frameRate: The suggested frame rate in fps.
    /// - Returns: The suggested format if all values are positive; otherwise `nil`.
    static func suggestedVideoFormat(
        width: Int,
        height: Int,
        frameRate: Int
    ) -> RealtimeVideoFormat? {
        guard width > 0, height > 0, frameRate > 0 else {
            return nil
        }
        return RealtimeVideoFormat(
            width: width,
            height: height,
            fps: frameRate
        )
    }
}

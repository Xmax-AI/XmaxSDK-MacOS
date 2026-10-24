@preconcurrency import AgoraRtcKit

/// Native camera operations can be exercised independently of a live Agora engine.
protocol AgoraRtcCameraEngine: AnyObject {
    func enableLocalVideo(_ enabled: Bool) -> Int32
    func startCameraCapture(_ sourceType: AgoraVideoSourceType, config: AgoraCameraCapturerConfiguration?) -> Int32
    func stopCameraCapture(_ sourceType: AgoraVideoSourceType) -> Int32
    func startPreview(_ sourceType: AgoraVideoSourceType) -> Int32
    func stopPreview(_ sourceType: AgoraVideoSourceType) -> Int32
    func setupLocalVideo(_ local: AgoraRtcVideoCanvas?) -> Int32
    func setDevice(_ type: AgoraMediaDeviceType, deviceId: String) -> Int32
}

extension AgoraRtcEngineKit: AgoraRtcCameraEngine {}

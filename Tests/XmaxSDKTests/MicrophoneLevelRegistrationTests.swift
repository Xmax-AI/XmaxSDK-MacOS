import Foundation
import XCTest
@testable import XmaxSDK

@MainActor
final class MicrophoneLevelRegistrationTests: XCTestCase {
    func testPublicRegistrationDoesNotInitializeRtcOrStartCapture() async {
        let platform = RtcPlatformStub()
        let creationCount = MicrophoneEngineCreationCount()
        let rtc = RtcManager(
            engineManager: RtcEngineManager(
                appID: "test",
                makeEngine: { _ in
                    creationCount.increment()
                    return platform
                },
                destroyEngine: {}
            )
        )
        let api = MicrophoneLevelAPIStub()
        let options = RealtimeConfiguration(model: .x2_1)
        let components = XmaxRealtimeFactory.make(options: options, apiService: api, rtcManager: rtc)
        let manager: any XmaxRealtimeManaging = XmaxRealtimeManager(options: options, components: components)
        var readings: [Float?] = []
        await manager.setMicrophoneLevelListener {
            MainActor.preconditionIsolated()
            readings.append($0)
        }
        XCTAssertEqual(readings.count, 1)
        XCTAssertNil(readings[0])
        XCTAssertEqual(api.requestCount, 0)
        XCTAssertEqual(creationCount.value, 0)
        await manager.setMicrophoneLevelListener(nil)
        await manager.close()
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(api.requestCount, 0)
    }
}

private final class MicrophoneEngineCreationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class MicrophoneLevelAPIStub: ApiServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.withLock { count } }

    func request<Response: Decodable & Sendable>(
        _ method: ApiMethod,
        path: String,
        body: Data?,
        as responseType: Response.Type
    ) async throws -> Response {
        lock.withLock { count += 1 }
        throw XmaxError(code: .apiError, message: "Input observation must not make network requests")
    }
}

//
//  XmaxClientCreditBalanceTests.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation
import XCTest
@testable import XmaxSDK

final class XmaxClientCreditBalanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ApiURLProtocolStub.reset()
    }

    func testQueryUsesAPIKeyAndGeneralEnvironmentAndPreservesFractionalCredits() async throws {
        for environment in XmaxEnvironment.allCases {
            ApiURLProtocolStub.setResponse(
                statusCode: 200,
                data: Data(#"{"success":true,"code":200,"data":{"currentBalance":1250.75}}"#.utf8)
            )
            let client = makeClient(apiKey: "  balance-key\n", environment: environment)

            let balance = try await client.getCreditBalance()

            XCTAssertEqual(balance.currentBalance, 1250.75)
            let request = try XCTUnwrap(ApiURLProtocolStub.request)
            let expectedURL = environment == .china
                ? "https://cloud.xmax.22duck.cn/open/api/v1/balance"
                : "https://api.xmax.cloud/open/api/v1/balance"
            XCTAssertEqual(request.url?.absoluteString, expectedURL)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "balance-key")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        }
    }

    func testZeroIsAValidServerConfirmedBalance() async throws {
        ApiURLProtocolStub.setResponse(
            statusCode: 200,
            data: Data(#"{"success":true,"data":{"currentBalance":0}}"#.utf8)
        )

        let balance = try await makeClient().getCreditBalance()

        XCTAssertEqual(balance.currentBalance, 0)
    }

    func testEachInvocationReadsTheLatestServerBalance() async throws {
        let client = makeClient()
        ApiURLProtocolStub.setResponse(
            statusCode: 200,
            data: Data(#"{"success":true,"data":{"currentBalance":100}}"#.utf8)
        )
        let initial = try await client.getCreditBalance()
        ApiURLProtocolStub.setResponse(
            statusCode: 200,
            data: Data(#"{"success":true,"data":{"currentBalance":25.5}}"#.utf8)
        )

        let refreshed = try await client.getCreditBalance()

        XCTAssertEqual(initial.currentBalance, 100)
        XCTAssertEqual(refreshed.currentBalance, 25.5)
    }

    func testEmptyKeyFailsBeforeSendingARequest() async {
        do {
            _ = try await makeClient(apiKey: " \n ").getCreditBalance()
            XCTFail("Expected an invalid API key")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .invalidAPIKey)
        }
        XCTAssertNil(ApiURLProtocolStub.request)
    }

    func testMissingAndMalformedBalancesFailInsteadOfBecomingZero() async {
        let client = makeClient()
        let payloads = [
            "null", "{}", #"{"currentBalance":null}"#, #"{"currentBalance":true}"#,
            #"{"currentBalance":"1250.75"}"#, #"{"currentBalance":-1}"#,
            #"{"currentBalance":1e400}"#, #"{"currentBalance":[]}"#
        ]
        for payload in payloads {
            ApiURLProtocolStub.setResponse(
                statusCode: 200,
                data: Data("{\"success\":true,\"data\":\(payload)}".utf8)
            )
            do {
                _ = try await client.getCreditBalance()
                XCTFail("Expected invalid balance data to fail: \(payload)")
            } catch {
                XCTAssertEqual((error as? XmaxError)?.code, .apiError, payload)
                XCTAssertEqual((error as? XmaxError)?.httpStatus, 200, payload)
            }
        }
    }

    func testHTTPAndBusinessErrorsPreserveServerDetails() async {
        for statusCode in [200, 401] {
            ApiURLProtocolStub.setResponse(
                statusCode: statusCode,
                data: Data(#"{"success":false,"code":46002,"message":"Invalid API key","data":null}"#.utf8)
            )
            do {
                _ = try await makeClient().getCreditBalance()
                XCTFail("Expected the server rejection")
            } catch {
                XCTAssertEqual(
                    error as? XmaxError,
                    XmaxError(code: .apiError, message: "Invalid API key", apiCode: 46002, httpStatus: statusCode)
                )
            }
        }
    }

    func testTransportFailureRemainsANetworkError() async {
        ApiURLProtocolStub.setError(URLError(.notConnectedToInternet))
        do {
            _ = try await makeClient().getCreditBalance()
            XCTFail("Expected a network failure")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .networkError)
        }
    }

    func testCancelledRequestRemainsCancelled() async {
        ApiURLProtocolStub.setError(URLError(.cancelled))
        do {
            _ = try await makeClient().getCreditBalance()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? XmaxError)?.code, .cancelled)
        }
    }

    private func makeClient(
        apiKey: String = "balance-key",
        environment: XmaxEnvironment = .china
    ) -> XmaxClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ApiURLProtocolStub.self]
        return XmaxClient(
            configuration: XmaxConfiguration(apiKey: apiKey, environment: environment),
            apiService: ApiService(
                apiKey: apiKey,
                baseURL: environment.apiBaseURL,
                session: URLSession(configuration: sessionConfiguration)
            )
        )
    }
}

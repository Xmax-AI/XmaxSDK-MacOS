//
//  XmaxConfiguration.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Global SDK configuration.
public struct XmaxConfiguration: Equatable, Sendable {

    /// The API key used to call Xmax services.
    public let apiKey: String

    /// The service environment, which also selects log detail language: Chinese domestically, English overseas.
    /// Log language is global and follows the most recently created client.
    public let environment: XmaxEnvironment

    /// The enabled SDK log types; logging is disabled by default.
    public let loggerOptions: XmaxLoggerOption

    /// Creates global SDK configuration.
    ///
    /// - Parameters:
    ///   - apiKey: The API key used to call Xmax services.
    ///   - environment: The SDK service environment; defaults to the domestic environment.
    ///   - loggerOptions: The SDK log types to enable; empty by default.
    public init(
        apiKey: String,
        environment: XmaxEnvironment = .china,
        loggerOptions: XmaxLoggerOption = []
    ) {
        let resolvedApiKey = apiKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.apiKey = resolvedApiKey
        self.environment = environment
        self.loggerOptions = loggerOptions
    }

    /// Checks that the API key is nonempty before server requests.
    ///
    /// - Throws: `XmaxError` if the API key is empty.
    public func validate() throws {
        guard !apiKey.isEmpty else {
            throw XmaxError(
                code: .invalidAPIKey,
                message: "API key cannot be empty"
            )
        }
    }
}

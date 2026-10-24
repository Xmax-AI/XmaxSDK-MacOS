//
//  ApiLogger.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// Logs API diagnostics without authentication data and includes response bodies on failure.
enum ApiLogger {

    /// Logs API response status and duration, including the response body on failure.
    ///
    /// - Parameters:
    ///   - method: The request HTTP method.
    ///   - path: The request path relative to the API base URL.
    ///   - statusCode: The HTTP response status code.
    ///   - bodyByteCount: The response body byte count.
    ///   - durationMs: The request duration in milliseconds.
    ///   - successful: Whether the request and business response succeeded.
    ///   - responseBody: The failure response body; successful bodies are not logged.
    static func logResponse(
        method: ApiMethod,
        path: String,
        statusCode: Int,
        bodyByteCount: Int,
        durationMs: Int,
        successful: Bool,
        responseBody: Data? = nil
    ) {
        let message = responseMessage(
            method: method,
            path: path,
            statusCode: statusCode,
            bodyByteCount: bodyByteCount,
            durationMs: durationMs,
            responseBody: successful ? nil : responseBody
        )
        if successful {
            XmaxLogger.api.debug(message: message)
        } else {
            XmaxLogger.api.error(message: message)
        }
    }

    /// Logs request errors occurring before a valid HTTP response arrives.
    ///
    /// - Parameters:
    ///   - method: The request HTTP method.
    ///   - path: The request path relative to the API base URL.
    ///   - error: The error occurring during the request.
    ///   - durationMs: The request duration in milliseconds.
    static func logFailure(
        method: ApiMethod,
        path: String,
        error: any Error,
        durationMs: Int
    ) {
        XmaxLogger.api.error(
            message: "\(method.rawValue) \(path) 失败 (Request Failed)\n"
                + "├─ \(XmaxLogger.localized("耗时：", "Duration: "))\(durationMs) ms\n"
                + "└─ \(XmaxLogger.localized("原因：", "Reason: "))\(ErrorMessageFormatter.format(error))"
        )
    }

    /// Creates log text with response metadata and an optional body.
    ///
    /// - Parameters:
    ///   - method: The request HTTP method.
    ///   - path: The request path relative to the API base URL.
    ///   - statusCode: The HTTP response status code.
    ///   - bodyByteCount: The response body byte count.
    ///   - durationMs: The request duration in milliseconds.
    ///   - responseBody: The response body to log; `nil` logs only its size.
    ///
    /// - Returns: Structured response log text in the current log language.
    static func responseMessage(
        method: ApiMethod,
        path: String,
        statusCode: Int,
        bodyByteCount: Int,
        durationMs: Int,
        responseBody: Data? = nil
    ) -> String {
        let prefix =
            "\(method.rawValue) \(path)\n" + "├─ \(XmaxLogger.localized("状态：", "Status: "))\(statusCode)\n"
            + "├─ \(XmaxLogger.localized("耗时：", "Duration: "))\(durationMs) ms\n"
        guard let responseBody else {
            return prefix + "└─ \(XmaxLogger.localized("响应：", "Response Size: "))\(bodyByteCount) bytes"
        }

        let body = formatResponseBody(responseBody)
        return prefix + "├─ \(XmaxLogger.localized("响应：", "Response Size: "))\(bodyByteCount) bytes\n"
            + "└─ \(XmaxLogger.localized("正文：", "Response Body: "))\n   \(body)"
    }

    /// Pretty-prints JSON bodies and emits other bodies as UTF-8 text.
    ///
    /// - Parameter data: The response body to format.
    ///
    /// - Returns: The printable body, or a placeholder if UTF-8 decoding fails.
    static func formatResponseBody(
        _ data: Data
    ) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let formattedData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let formattedBody = String(
                data: formattedData,
                encoding: .utf8
            )
        else {
            return String(
                data: data,
                encoding: .utf8
            ) ?? "<Non-UTF-8 response body>"
        }
        return formattedBody.replacingOccurrences(
            of: "\n",
            with: "\n   "
        )
    }
}

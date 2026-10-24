//
//  ApiServicing.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import Foundation

/// HTTP methods supported by the Xmax API.
enum ApiMethod: String, Sendable {

    /// Reads a server resource.
    case get = "GET"

    /// Submits data or creates a resource.
    case post = "POST"

    /// Updates a server resource.
    case put = "PUT"

    /// Deletes a server resource.
    case delete = "DELETE"
}

/// Defines basic Xmax API request capabilities.
protocol ApiServicing: Sendable {

    /// Sends an HTTP request and decodes response data to the specified type.
    ///
    /// - Parameters:
    ///   - method: The request HTTP method.
    ///   - path: The request path relative to the API base URL.
    ///   - body: The encoded request body; `nil` omits the body.
    ///   - responseType: The response data decoding type.
    ///
    /// - Returns: The business data parsed from the API response.
    ///
    /// - Throws: An error on invalid credentials or URL, request failure, server error, or response parsing failure.
    func request<Response: Decodable & Sendable>(
        _ method: ApiMethod,
        path: String,
        body: Data?,
        as responseType: Response.Type
    ) async throws -> Response
}

extension ApiServicing {

    /// Sends a GET request and parses response data.
    ///
    /// - Parameters:
    ///   - path: The request path relative to the API base URL.
    ///   - responseType: The response data decoding type.
    ///
    /// - Returns: The business data parsed from the API response.
    ///
    /// - Throws: An error on request failure, server error, or response parsing failure.
    func get<Response: Decodable & Sendable>(
        _ path: String,
        as responseType: Response.Type
    ) async throws -> Response {
        try await request(
            .get,
            path: path,
            body: nil,
            as: responseType
        )
    }

    /// Sends a POST request and parses response data.
    ///
    /// - Parameters:
    ///   - path: The request path relative to the API base URL.
    ///   - responseType: The response data decoding type.
    ///
    /// - Returns: The business data parsed from the API response.
    ///
    /// - Throws: An error on request failure, server error, or response parsing failure.
    func post<Response: Decodable & Sendable>(
        _ path: String,
        as responseType: Response.Type
    ) async throws -> Response {
        try await request(
            .post,
            path: path,
            body: nil,
            as: responseType
        )
    }

    /// Sends a POST request with a JSON body.
    ///
    /// - Parameters:
    ///   - path: The request path relative to the API base URL.
    ///   - body: The request data to encode as JSON.
    ///   - responseType: The response data decoding type.
    ///
    /// - Returns: The business data parsed from the API response.
    ///
    /// - Throws: An error on body encoding failure, request failure, server error, or response parsing failure.
    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as responseType: Response.Type
    ) async throws -> Response {
        try await request(
            .post,
            path: path,
            body: try encode(body),
            as: responseType
        )
    }

    /// Sends a PUT request and parses response data.
    ///
    /// - Parameters:
    ///   - path: The request path relative to the API base URL.
    ///   - responseType: The response data decoding type.
    ///
    /// - Returns: The business data parsed from the API response.
    ///
    /// - Throws: An error on request failure, server error, or response parsing failure.
    func put<Response: Decodable & Sendable>(
        _ path: String,
        as responseType: Response.Type
    ) async throws -> Response {
        try await request(
            .put,
            path: path,
            body: nil,
            as: responseType
        )
    }

    /// Sends a PUT request with a JSON body.
    ///
    /// - Parameters:
    ///   - path: The request path relative to the API base URL.
    ///   - body: The request data to encode as JSON.
    ///   - responseType: The response data decoding type.
    ///
    /// - Returns: The business data parsed from the API response.
    ///
    /// - Throws: An error on body encoding failure, request failure, server error, or response parsing failure.
    func put<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as responseType: Response.Type
    ) async throws -> Response {
        try await request(
            .put,
            path: path,
            body: try encode(body),
            as: responseType
        )
    }

    /// Sends a DELETE request and parses response data.
    ///
    /// - Parameters:
    ///   - path: The request path relative to the API base URL.
    ///   - responseType: The response data decoding type.
    ///
    /// - Returns: The business data parsed from the API response.
    ///
    /// - Throws: An error on request failure, server error, or response parsing failure.
    func delete<Response: Decodable & Sendable>(
        _ path: String,
        as responseType: Response.Type
    ) async throws -> Response {
        try await request(
            .delete,
            path: path,
            body: nil,
            as: responseType
        )
    }

    /// Encodes request data as JSON.
    ///
    /// - Parameter body: The encodable request data.
    ///
    /// - Returns: The JSON data for the HTTP request body.
    ///
    /// - Throws: An API error if JSON encoding fails.
    private func encode<Body: Encodable & Sendable>(
        _ body: Body
    ) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw XmaxError(
                code: .apiError,
                message: "Failed to encode API request body: " + ErrorMessageFormatter.format(error)
            )
        }
    }
}

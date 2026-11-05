//
//  XmaxClient.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// Unified SDK entry point for realtime generation, storage, media services, and account credit queries.
public final class XmaxClient: Sendable {

    /// The client's global configuration.
    public let configuration: XmaxConfiguration

    /// The service used for storage credentials, media safety checks, and account credit queries.
    private let apiService: any ApiServicing

    /// Creates an SDK client.
    ///
    /// - Parameter configuration: Global SDK configuration.
    public init(
        configuration: XmaxConfiguration
    ) {
        self.configuration = configuration
        XmaxLogger.configure(
            options: configuration.loggerOptions,
            environment: configuration.environment
        )
        apiService = ApiService(
            apiKey: configuration.apiKey,
            baseURL: configuration.environment.apiBaseURL
        )
    }

    /// Creates an SDK client with the specified API service.
    ///
    /// - Parameters:
    ///   - configuration: The client configuration, which also sets global log options and language.
    ///   - apiService: The service used for storage and account credit queries.
    init(
        configuration: XmaxConfiguration,
        apiService: any ApiServicing
    ) {
        self.configuration = configuration
        XmaxLogger.configure(
            options: configuration.loggerOptions,
            environment: configuration.environment
        )
        self.apiService = apiService
    }

    /// Creates a component managing local media, realtime connections, and generation tasks.
    ///
    /// Component creation and local preview do not validate the API key; server access validates credentials.
    /// Realtime requests use the client's environment independently of the selected model.
    ///
    /// - Parameter options: Business configuration including the realtime generation model.
    ///
    /// - Returns: The component managing local camera or external media and realtime generation.
    @MainActor
    public func createRealtimeManager(
        options: RealtimeConfiguration
    ) -> any XmaxRealtimeManaging {
        XmaxRealtimeManager(
            options: options,
            apiService: ApiService(
                apiKey: configuration.apiKey,
                baseURL: configuration.environment.realtimeApiBaseURL
            )
        )
    }

    /// Creates a file storage manager.
    ///
    /// - Returns: The storage manager for uploading and downloading media files.
    ///
    /// - Throws: `XmaxError` if the global SDK configuration is invalid.
    public func createStorageManager() throws -> any XmaxStorageManaging {
        try configuration.validate()
        return XmaxStorageManager(apiService: apiService)
    }

    /// Fetches the remaining credits for the account owning this client's API key.
    ///
    /// Each call requests the current server balance using the client's general service environment.
    /// Your app controls when to refresh the balance and how to handle insufficient credits.
    ///
    /// - Returns: The server-reported balance, in credits, including fractional credits.
    ///
    /// - Throws: `XmaxError` on invalid credentials, request failure, an invalid response, or cancellation.
    public func getCreditBalance() async throws -> XmaxCreditBalance {
        try configuration.validate()
        return try await apiService.get(
            "/balance",
            as: XmaxCreditBalance.self
        )
    }

    /// Creates a media processing and capability query service.
    ///
    /// - Parameter model: The model defining media input rules; defaults to `x2.1`.
    ///
    /// - Returns: The service calculating model input dimensions and querying platform media capabilities.
    public func createMediaService(
        model: RealtimeModel = .x2_1
    ) -> any MediaServicing {
        MediaService(model: model)
    }
}

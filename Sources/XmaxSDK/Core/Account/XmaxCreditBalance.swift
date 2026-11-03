//
//  XmaxCreditBalance.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The server-reported credit balance for the account owning the client's API key.
public struct XmaxCreditBalance: Decodable, Equatable, Sendable {

    /// The remaining credits as a finite, nonnegative value, including fractional credits.
    public let currentBalance: Double

    /// Decodes a balance, rejecting missing, malformed, negative, or nonfinite credit values.
    ///
    /// - Parameter decoder: The decoder reading the server's balance data.
    ///
    /// - Throws: A decoding error if the balance is absent or invalid.
    public init(
        from decoder: any Decoder
    ) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(
            Double.self,
            forKey: .currentBalance
        )
        guard value.isFinite, value >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .currentBalance,
                in: container,
                debugDescription: "Credit balance must be a finite, nonnegative number"
            )
        }
        currentBalance = value
    }

    /// Maps the server's balance field to the public result.
    private enum CodingKeys: String, CodingKey {

        /// The remaining account credits.
        case currentBalance
    }
}

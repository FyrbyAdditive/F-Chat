// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// The per-server JSON blob persisted in the Keychain alongside the
/// access + refresh tokens. Holds everything the coordinator needs to
/// drive a refresh without re-doing discovery: token-endpoint URL,
/// registered client credentials, expiry tracker, requested scope.
///
/// Stored as a Keychain entry named via
/// `KeychainAccount.mcpTokenMetadata(_:)`. Encoded with `JSONEncoder`
/// using `dateEncodingStrategy = .iso8601`.
public struct TokenMetadata: Codable, Sendable, Hashable {
    public var tokenEndpoint: URL
    public var clientID: String
    public var clientSecret: String?
    public var registrationAccessToken: String?
    public var scope: String?
    public var expiresAt: Date?
    public var resource: URL?

    public init(
        tokenEndpoint: URL,
        clientID: String,
        clientSecret: String? = nil,
        registrationAccessToken: String? = nil,
        scope: String? = nil,
        expiresAt: Date? = nil,
        resource: URL? = nil
    ) {
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.registrationAccessToken = registrationAccessToken
        self.scope = scope
        self.expiresAt = expiresAt
        self.resource = resource
    }

    public func encode() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func decode(_ raw: String) throws -> TokenMetadata {
        guard let data = raw.data(using: .utf8) else {
            throw AuthError.configurationError(reason: "metadata blob is not utf8")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TokenMetadata.self, from: data)
    }
}

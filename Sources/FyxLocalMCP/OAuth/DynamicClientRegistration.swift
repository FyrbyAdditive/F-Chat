// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// RFC 7591 dynamic client registration. Called when the user hasn't
/// provided a manual `client_id` and the authorization server exposes a
/// `registration_endpoint`. Result is persisted in the per-server
/// `TokenMetadata` blob so we don't re-register on every launch.
public struct DynamicClientRegistration: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String?
    public let registrationAccessToken: String?
    public let clientSecretExpiresAt: Date?

    public static func register(
        at endpoint: URL,
        clientName: String,
        redirectURIs: [String],
        scope: String?,
        session: URLSession
    ) async throws -> DynamicClientRegistration {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var payload: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": redirectURIs,
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ]
        if let scope { payload["scope"] = scope }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.registrationFailed(reason: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw AuthError.registrationFailed(reason: "HTTP \(http.statusCode): \(body)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError.registrationFailed(reason: "non-JSON body")
        }
        guard let clientID = json["client_id"] as? String else {
            throw AuthError.registrationFailed(reason: "missing client_id in response")
        }
        let secret = json["client_secret"] as? String
        let registrationAccessToken = json["registration_access_token"] as? String
        let expiry = (json["client_secret_expires_at"] as? Int).flatMap { ts -> Date? in
            // RFC 7591: 0 means never expires.
            ts == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(ts))
        }
        return DynamicClientRegistration(
            clientID: clientID,
            clientSecret: secret,
            registrationAccessToken: registrationAccessToken,
            clientSecretExpiresAt: expiry
        )
    }
}

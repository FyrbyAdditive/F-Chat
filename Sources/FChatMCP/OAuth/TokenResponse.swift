// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// RFC 6749 §5.1 token-endpoint successful response shape (and §5.2 the
/// error shape). Returned by the authorization code exchange and by
/// refresh-token rotation.
public struct TokenResponse: Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: TimeInterval?
    public let refreshToken: String?
    public let scope: String?

    /// `expiresIn` resolved against a base time (typically issue time).
    /// nil when the server didn't advertise an `expires_in` value.
    public func expiresAt(issuedAt: Date) -> Date? {
        expiresIn.map { issuedAt.addingTimeInterval($0) }
    }

    public static func parse(_ data: Data) throws -> TokenResponse {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError.exchangeFailed(reason: "non-JSON token response")
        }
        if let err = json["error"] as? String {
            let description = (json["error_description"] as? String) ?? err
            if err == "invalid_grant" {
                throw AuthError.needsReAuthentication
            }
            throw AuthError.exchangeFailed(reason: "\(err): \(description)")
        }
        guard let accessToken = json["access_token"] as? String else {
            throw AuthError.exchangeFailed(reason: "missing access_token")
        }
        let tokenType = (json["token_type"] as? String) ?? "Bearer"
        let expiresIn: TimeInterval?
        if let n = json["expires_in"] as? Double { expiresIn = n }
        else if let n = json["expires_in"] as? Int { expiresIn = TimeInterval(n) }
        else { expiresIn = nil }
        let refreshToken = json["refresh_token"] as? String
        let scope = json["scope"] as? String

        return TokenResponse(
            accessToken: accessToken,
            tokenType: tokenType,
            expiresIn: expiresIn,
            refreshToken: refreshToken,
            scope: scope
        )
    }
}

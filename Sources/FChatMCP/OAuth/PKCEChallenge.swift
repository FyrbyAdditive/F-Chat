// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import CryptoKit

/// PKCE (RFC 7636) verifier + S256 challenge pair, generated once per
/// authorization request. The verifier is held until we exchange the
/// authorization code; the challenge is sent on the auth URL.
public struct PKCEChallenge: Sendable, Hashable {
    public let verifier: String
    public let challenge: String

    /// Generate a fresh, cryptographically random verifier (43 chars after
    /// base64url encoding of 32 random bytes — the upper end of the spec
    /// range) and the corresponding S256 challenge.
    public static func generate() -> PKCEChallenge {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBufferPointer {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        let verifier = Data(bytes).base64URLEncodedString()
        let challenge = Self.s256Challenge(for: verifier)
        return PKCEChallenge(verifier: verifier, challenge: challenge)
    }

    /// The S256 challenge of a verifier — base64url(SHA256(verifier)).
    /// Public for testing; the only caller is `generate()` in production.
    public static func s256Challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// Base64URL encoding with no padding (RFC 4648 §5).
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

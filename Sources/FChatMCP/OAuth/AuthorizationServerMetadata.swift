import Foundation

/// RFC 8414 authorization-server metadata. Tells us where to send the
/// user's browser, where to POST for tokens, and (optionally) where to
/// register dynamic clients.
public struct AuthorizationServerMetadata: Sendable, Equatable {
    public let issuer: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let registrationEndpoint: URL?
    public let codeChallengeMethodsSupported: [String]
    public let grantTypesSupported: [String]
    public let scopesSupported: [String]

    /// Returns true if S256 PKCE is supported (required by MCP).
    public var supportsS256PKCE: Bool {
        codeChallengeMethodsSupported.contains("S256")
    }

    public var supportsAuthorizationCode: Bool {
        // Some servers omit grant_types_supported entirely, in which
        // case the OAuth default (`authorization_code` + `implicit`)
        // applies per spec.
        grantTypesSupported.isEmpty || grantTypesSupported.contains("authorization_code")
    }

    public var supportsRefreshToken: Bool {
        grantTypesSupported.contains("refresh_token")
    }

    public static func fetch(
        authorizationServer: URL,
        session: URLSession
    ) async throws -> AuthorizationServerMetadata {
        let url = wellKnownURL(for: authorizationServer)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.discoveryFailed(reason: "non-HTTP response from \(url)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.discoveryFailed(reason: "HTTP \(http.statusCode) from \(url)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError.discoveryFailed(reason: "non-JSON body from \(url)")
        }

        guard let issuer = json["issuer"] as? String else {
            throw AuthError.missingMetadata(field: "issuer")
        }
        guard let authString = json["authorization_endpoint"] as? String,
              let authURL = URL(string: authString) else {
            throw AuthError.missingMetadata(field: "authorization_endpoint")
        }
        guard let tokenString = json["token_endpoint"] as? String,
              let tokenURL = URL(string: tokenString) else {
            throw AuthError.missingMetadata(field: "token_endpoint")
        }
        let registrationURL = (json["registration_endpoint"] as? String).flatMap { URL(string: $0) }
        let methods = (json["code_challenge_methods_supported"] as? [String]) ?? []
        let grants = (json["grant_types_supported"] as? [String]) ?? []
        let scopes = (json["scopes_supported"] as? [String]) ?? []

        return AuthorizationServerMetadata(
            issuer: issuer,
            authorizationEndpoint: authURL,
            tokenEndpoint: tokenURL,
            registrationEndpoint: registrationURL,
            codeChallengeMethodsSupported: methods,
            grantTypesSupported: grants,
            scopesSupported: scopes
        )
    }

    /// `<authServer>/.well-known/oauth-authorization-server`.
    /// Per RFC 8414 §3.1 the path is appended to the issuer URL's
    /// host root.
    static func wellKnownURL(for authorizationServer: URL) -> URL {
        var components = URLComponents()
        components.scheme = authorizationServer.scheme
        components.host = authorizationServer.host
        components.port = authorizationServer.port
        // Preserve any sub-path; the .well-known segment is inserted
        // between the host root and the path. (Some servers host the
        // authorization-server document at the root; others scope it
        // to a path. We default to root for compatibility.)
        components.path = "/.well-known/oauth-authorization-server"
        return components.url ?? authorizationServer
    }

    public static func wellKnownURL(for authorizationServer: URL, document: String) -> URL {
        var components = URLComponents()
        components.scheme = authorizationServer.scheme
        components.host = authorizationServer.host
        components.port = authorizationServer.port
        components.path = "/.well-known/\(document)"
        return components.url ?? authorizationServer
    }

    /// Probe a server origin directly for auth-server metadata, trying
    /// `oauth-authorization-server` then `openid-configuration`. Used
    /// in the discovery cascade when a server is its own authorization
    /// server and doesn't expose protected-resource-metadata. Returns
    /// nil when neither document resolves.
    public static func probeOrigin(
        _ origin: URL,
        session: URLSession
    ) async -> AuthorizationServerMetadata? {
        for document in ["oauth-authorization-server", "openid-configuration"] {
            let url = wellKnownURL(for: origin, document: document)
            if let meta = try? await fetchExact(url, session: session) {
                return meta
            }
        }
        return nil
    }

    /// Fetch + parse from an exact .well-known URL (no rebasing).
    public static func fetchExact(
        _ url: URL,
        session: URLSession
    ) async throws -> AuthorizationServerMetadata {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.discoveryFailed(reason: "no metadata at \(url)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError.discoveryFailed(reason: "non-JSON body from \(url)")
        }
        guard let issuer = json["issuer"] as? String,
              let authString = json["authorization_endpoint"] as? String,
              let authURL = URL(string: authString),
              let tokenString = json["token_endpoint"] as? String,
              let tokenURL = URL(string: tokenString) else {
            throw AuthError.missingMetadata(field: "authorization_endpoint/token_endpoint")
        }
        let registrationURL = (json["registration_endpoint"] as? String).flatMap { URL(string: $0) }
        let methods = (json["code_challenge_methods_supported"] as? [String]) ?? []
        let grants = (json["grant_types_supported"] as? [String]) ?? []
        let scopes = (json["scopes_supported"] as? [String]) ?? []
        return AuthorizationServerMetadata(
            issuer: issuer,
            authorizationEndpoint: authURL,
            tokenEndpoint: tokenURL,
            registrationEndpoint: registrationURL,
            codeChallengeMethodsSupported: methods,
            grantTypesSupported: grants,
            scopesSupported: scopes
        )
    }
}

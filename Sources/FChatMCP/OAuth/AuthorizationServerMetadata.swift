// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

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
        // Try candidate well-known locations in priority order. RFC 8414
        // §3.1 says that when the issuer URL has a path component, the
        // `.well-known/oauth-authorization-server` segment is inserted
        // between the host and that path — NOT appended at the host root.
        // Auth servers like Atlassian's (https://auth.atlassian.com/<tenant>)
        // only expose `registration_endpoint` on the path-aware document;
        // the host-root document omits it, which previously broke DCR.
        // We try path-aware first, then host-root, then the OIDC variants.
        var lastError: Error = AuthError.discoveryFailed(reason: "no candidates for \(authorizationServer)")
        for url in candidateURLs(for: authorizationServer) {
            do {
                return try await fetchExact(url, session: session)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Ordered well-known candidate URLs for an authorization server.
    static func candidateURLs(for authorizationServer: URL) -> [URL] {
        var urls: [URL] = []
        let path = authorizationServer.path
        let hasPath = !path.isEmpty && path != "/"
        for document in ["oauth-authorization-server", "openid-configuration"] {
            if hasPath {
                // Path-aware: /.well-known/<doc><path>.
                urls.append(wellKnownURL(for: authorizationServer, document: document, includingPath: true))
            }
            // Host-root: /.well-known/<doc>.
            urls.append(wellKnownURL(for: authorizationServer, document: document))
        }
        return urls
    }

    /// `<authServer-host>/.well-known/oauth-authorization-server`.
    static func wellKnownURL(for authorizationServer: URL) -> URL {
        wellKnownURL(for: authorizationServer, document: "oauth-authorization-server")
    }

    public static func wellKnownURL(for authorizationServer: URL, document: String) -> URL {
        wellKnownURL(for: authorizationServer, document: document, includingPath: false)
    }

    /// Build a well-known URL for the given document. When
    /// `includingPath` is true and the server URL has a path, the
    /// `.well-known/<document>` segment is inserted between the host
    /// and the issuer path per RFC 8414 §3.1
    /// (`https://host/.well-known/<document>/<tenant-path>`).
    public static func wellKnownURL(for authorizationServer: URL, document: String, includingPath: Bool) -> URL {
        var components = URLComponents()
        components.scheme = authorizationServer.scheme
        components.host = authorizationServer.host
        components.port = authorizationServer.port
        if includingPath {
            let path = authorizationServer.path
            let suffix = path.hasPrefix("/") ? path : "/" + path
            components.path = "/.well-known/\(document)" + suffix
        } else {
            components.path = "/.well-known/\(document)"
        }
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

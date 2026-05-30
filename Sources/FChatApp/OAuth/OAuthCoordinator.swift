// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatMCP
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// Drives the full per-server OAuth 2.1 flow for HTTP MCP transports.
///
/// Discovery (RFC 9728 + RFC 8414) → optional dynamic client registration
/// (RFC 7591) → PKCE authorization-code flow via
/// `ASWebAuthenticationSession` → token exchange → refresh. The
/// authorization-code step's `resource` parameter carries the MCP
/// server URL per RFC 8707.
///
/// Tokens live in the Keychain:
/// - `KeychainAccount.mcpAccessToken(id)`
/// - `KeychainAccount.mcpRefreshToken(id)`
/// - `KeychainAccount.mcpTokenMetadata(id)` (JSON blob carrying
///   client credentials + expiry + token-endpoint URL)
///
/// Refresh strategy is eager + lazy: callers ask for a token via
/// `accessToken(for:httpConfig:)`, which auto-refreshes ~60s before
/// expiry. The HTTP transport additionally calls back into the
/// coordinator on a 401 to force a refresh + retry.
@MainActor
final class OAuthCoordinator {
    /// Time-to-expiry threshold that triggers an eager refresh. ~60s
    /// is enough to comfortably finish a single chat send before the
    /// token actually expires server-side.
    private static let eagerRefreshLeeway: TimeInterval = 60
    /// Native URL scheme for our OAuth redirect URI
    /// (`fchat://oauth/callback`). Registered in the .app's Info.plist
    /// via make-app.sh; ASWebAuthenticationSession dispatches the
    /// redirect back to us automatically.
    static let redirectURI = "fchat://oauth/callback"
    static let callbackURLScheme = "fchat"

    private let secretStore: any SecretStore
    private let session: URLSession
    /// In-memory cache of authorization-server metadata so we don't
    /// re-fetch the .well-known docs on every refresh. Keyed by
    /// authorization-server URL.
    private var metadataCache: [URL: AuthorizationServerMetadata] = [:]

    init(secretStore: any SecretStore, session: URLSession? = nil) {
        self.secretStore = secretStore
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public

    /// Returns a usable access token, doing whatever's needed:
    /// 1. Reads cached token from Keychain.
    /// 2. If absent or near-expiry, refreshes.
    /// 3. If no refresh token (or refresh fails as invalid_grant),
    ///    walks the interactive sign-in flow.
    func accessToken(
        for serverID: MCPServerID,
        resource: URL,
        httpConfig: MCPTransportConfig.HTTPConfig
    ) async throws -> String {
        // Existing tokens path.
        if let existing = try await loadAccessToken(for: serverID),
           let metadata = try await loadMetadata(for: serverID) {
            let needsRefresh = (metadata.expiresAt ?? .distantFuture)
                .timeIntervalSinceNow < Self.eagerRefreshLeeway
            if !needsRefresh {
                return existing
            }
            // Try refresh first; fall through to interactive if it fails.
            if let refresh = try await loadRefreshToken(for: serverID) {
                do {
                    let response = try await refreshTokens(
                        serverID: serverID,
                        refreshToken: refresh,
                        metadata: metadata,
                        resource: resource
                    )
                    return response.accessToken
                } catch AuthError.needsReAuthentication {
                    await clearTokens(for: serverID)
                    // Fall through to interactive.
                } catch {
                    // Other failures bubble up. The UI surfaces them; the
                    // user can hit "Sign in" to force a fresh flow.
                    throw error
                }
            }
        }

        // No cached token, or refresh failed irrecoverably → interactive.
        return try await interactiveSignIn(
            serverID: serverID,
            resource: resource,
            httpConfig: httpConfig
        )
    }

    /// Force interactive re-authentication regardless of cached state.
    /// Used by the Settings UI "Sign in" / "Re-authenticate" button.
    func reauthorize(
        serverID: MCPServerID,
        resource: URL,
        httpConfig: MCPTransportConfig.HTTPConfig
    ) async throws {
        await clearTokens(for: serverID)
        _ = try await interactiveSignIn(
            serverID: serverID,
            resource: resource,
            httpConfig: httpConfig
        )
    }

    /// Drop every token + metadata blob for this server. Called from
    /// sign-out and from the registry when a server is deleted.
    func clearTokens(for serverID: MCPServerID) async {
        try? await secretStore.deleteSecret(for: KeychainAccount.mcpAccessToken(serverID))
        try? await secretStore.deleteSecret(for: KeychainAccount.mcpRefreshToken(serverID))
        try? await secretStore.deleteSecret(for: KeychainAccount.mcpTokenMetadata(serverID))
    }

    /// Quick read used by the UI to decide whether to show "Sign in" or
    /// "Re-authenticate".
    func hasStoredAccessToken(for serverID: MCPServerID) async -> Bool {
        ((try? await secretStore.secret(for: KeychainAccount.mcpAccessToken(serverID))) ?? nil) != nil
    }

    // MARK: - Interactive sign-in

    private func interactiveSignIn(
        serverID: MCPServerID,
        resource: URL,
        httpConfig: MCPTransportConfig.HTTPConfig
    ) async throws -> String {
        // 1 + 2. Discover the authorization server + its metadata via a
        // resilient cascade. Real MCP servers vary wildly in how they
        // advertise OAuth; try every documented mechanism in order.
        let asMeta = try await discoverAuthorizationServer(
            resource: resource,
            httpConfig: httpConfig
        )
        guard asMeta.supportsS256PKCE else {
            throw AuthError.configurationError(reason: "server doesn't advertise S256 PKCE")
        }
        guard asMeta.supportsAuthorizationCode else {
            throw AuthError.configurationError(reason: "server doesn't support authorization_code grant")
        }

        // 3. Resolve / register client.
        let clientID: String
        let clientSecret: String?
        let registrationAccessToken: String?
        if let manual = httpConfig.oauthClientID, !manual.isEmpty {
            clientID = manual
            clientSecret = nil
            registrationAccessToken = nil
        } else if let registrationEndpoint = asMeta.registrationEndpoint {
            let registration = try await DynamicClientRegistration.register(
                at: registrationEndpoint,
                clientName: "F-Chat",
                redirectURIs: [Self.redirectURI],
                scope: httpConfig.oauthScopes,
                session: session
            )
            clientID = registration.clientID
            clientSecret = registration.clientSecret
            registrationAccessToken = registration.registrationAccessToken
        } else {
            throw AuthError.configurationError(reason: "no client_id provided and server has no registration_endpoint")
        }

        // 4. Build authorization URL.
        let pkce = PKCEChallenge.generate()
        let state = Self.generateState()
        let resourceIndicator = httpConfig.oauthResourceIndicator ?? resource
        let scope = httpConfig.oauthScopes ?? asMeta.scopesSupported.joined(separator: " ")
        let authURL = try buildAuthorizationURL(
            base: asMeta.authorizationEndpoint,
            clientID: clientID,
            challenge: pkce.challenge,
            state: state,
            scope: scope,
            resource: resourceIndicator
        )

        // 5. Open in ASWebAuthenticationSession.
        let callback = try await runWebAuthenticationSession(url: authURL)
        let (code, returnedState) = try parseCallback(callback)
        guard returnedState == state else {
            throw AuthError.stateMismatch
        }

        // 6. Exchange code for tokens.
        let tokens = try await exchangeCodeForTokens(
            tokenEndpoint: asMeta.tokenEndpoint,
            code: code,
            verifier: pkce.verifier,
            clientID: clientID,
            clientSecret: clientSecret,
            resource: resourceIndicator
        )

        // 7. Persist.
        let metadata = TokenMetadata(
            tokenEndpoint: asMeta.tokenEndpoint,
            clientID: clientID,
            clientSecret: clientSecret,
            registrationAccessToken: registrationAccessToken,
            scope: tokens.scope ?? scope,
            expiresAt: tokens.expiresAt(issuedAt: .now),
            resource: resourceIndicator
        )
        try await persistTokens(
            serverID: serverID,
            tokens: tokens,
            metadata: metadata
        )
        return tokens.accessToken
    }

    // MARK: - Refresh

    @discardableResult
    private func refreshTokens(
        serverID: MCPServerID,
        refreshToken: String,
        metadata: TokenMetadata,
        resource: URL
    ) async throws -> TokenResponse {
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": metadata.clientID,
            "resource": (metadata.resource ?? resource).absoluteString,
        ]
        if let secret = metadata.clientSecret { params["client_secret"] = secret }
        request.httpBody = Self.formURLEncoded(params)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.refreshFailed(reason: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Try to surface invalid_grant as the canonical
            // re-auth-needed signal — it can come back as 4xx too.
            if let parsed = (try? TokenResponse.parse(data)) {
                // parse() throws on errors, so a returned value here is
                // surprising — shouldn't happen for non-2xx. Treat as
                // generic refresh failure.
                _ = parsed
            } else if let body = String(data: data, encoding: .utf8),
                      body.contains("invalid_grant") {
                throw AuthError.needsReAuthentication
            }
            throw AuthError.refreshFailed(reason: "HTTP \(http.statusCode)")
        }
        let parsed = try TokenResponse.parse(data)
        // Persist the refreshed tokens. Some servers rotate refresh
        // tokens; honour the new one if present.
        var updatedMetadata = metadata
        updatedMetadata.expiresAt = parsed.expiresAt(issuedAt: .now)
        if let newScope = parsed.scope { updatedMetadata.scope = newScope }
        try await persistTokens(
            serverID: serverID,
            tokens: parsed,
            metadata: updatedMetadata,
            // If the response didn't include a new refresh_token, keep
            // the old one rather than clobbering.
            fallbackRefreshToken: refreshToken
        )
        return parsed
    }

    private func exchangeCodeForTokens(
        tokenEndpoint: URL,
        code: String,
        verifier: String,
        clientID: String,
        clientSecret: String?,
        resource: URL
    ) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var params: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "resource": resource.absoluteString,
        ]
        if let secret = clientSecret { params["client_secret"] = secret }
        request.httpBody = Self.formURLEncoded(params)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.exchangeFailed(reason: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Try to extract the error payload.
            if let body = String(data: data, encoding: .utf8) {
                throw AuthError.exchangeFailed(reason: "HTTP \(http.statusCode): \(body.prefix(200))")
            }
            throw AuthError.exchangeFailed(reason: "HTTP \(http.statusCode)")
        }
        return try TokenResponse.parse(data)
    }

    // MARK: - Authorization URL + browser handoff

    private func buildAuthorizationURL(
        base: URL,
        clientID: String,
        challenge: String,
        state: String,
        scope: String,
        resource: URL
    ) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AuthError.configurationError(reason: "invalid authorization_endpoint")
        }
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // RFC 8707 resource indicator.
            URLQueryItem(name: "resource", value: resource.absoluteString),
        ])
        if !scope.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw AuthError.configurationError(reason: "couldn't build authorization URL")
        }
        return url
    }

    private func runWebAuthenticationSession(url: URL) async throws -> URL {
        #if canImport(AuthenticationServices)
        // Configure + start the session here on the main actor (UIKit/AppKit
        // presentation must be main-thread). The completion handler, though,
        // is invoked by AuthenticationServices on a background XPC queue —
        // so it must NOT be main-actor-isolated, or Swift's runtime traps
        // with a dispatch_assert_queue failure (the observed crash). We
        // hand it a `@Sendable` closure that does only thread-safe work:
        // resume the continuation with the raw URL/Error, both Sendable.
        // The session object is retained for the duration of the await by
        // the continuation closure's capture.
        let scheme = Self.callbackURLScheme
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let handler: @Sendable (URL?, (any Error)?) -> Void = { callbackURL, error in
                if let error {
                    let nsErr = error as NSError
                    if nsErr.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: AuthError.userCancelled)
                        return
                    }
                    continuation.resume(throwing: AuthError.authorizationDenied(reason: error.localizedDescription))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.authorizationDenied(reason: "empty callback"))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme,
                completionHandler: handler
            )
            session.presentationContextProvider = ContextProvider.shared
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: AuthError.configurationError(reason: "couldn't start ASWebAuthenticationSession"))
            }
        }
        #else
        throw AuthError.configurationError(reason: "AuthenticationServices not available on this platform")
        #endif
    }

    private func parseCallback(_ url: URL) throws -> (code: String, state: String?) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AuthError.authorizationDenied(reason: "malformed callback URL")
        }
        let items = components.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value ?? err
            throw AuthError.authorizationDenied(reason: "\(err): \(description)")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.authorizationDenied(reason: "no code in callback")
        }
        let state = items.first(where: { $0.name == "state" })?.value
        return (code, state)
    }

    // MARK: - Discovery cascade

    /// Resolve the authorization server's metadata using every
    /// mechanism MCP servers use in the wild, stopping at the first
    /// success. Throws a single descriptive error listing what was
    /// tried if none resolve.
    private func discoverAuthorizationServer(
        resource: URL,
        httpConfig: MCPTransportConfig.HTTPConfig
    ) async throws -> AuthorizationServerMetadata {
        var attempts: [String] = []

        // 1. Explicit override.
        if let override = httpConfig.oauthAuthorizationServerURL {
            return try await fetchAuthorizationServerMetadata(override)
        }

        // 2. Unauthenticated probe → WWW-Authenticate resource_metadata.
        if let metadataURL = await probeResourceMetadataURL(resource: resource) {
            attempts.append("WWW-Authenticate resource_metadata")
            if let meta = try? await resolveViaProtectedResource(metadataURLFetch: {
                try await ProtectedResourceMetadata.fetch(at: metadataURL, session: self.session)
            }) {
                return meta
            }
        }

        // 3. Host-root protected-resource-metadata.
        attempts.append("host-root /.well-known/oauth-protected-resource")
        if let meta = try? await resolveViaProtectedResource(metadataURLFetch: {
            try await ProtectedResourceMetadata.fetch(resource: resource, session: self.session)
        }) {
            return meta
        }

        // 4. Path-scoped protected-resource-metadata.
        if let pathScoped = ProtectedResourceMetadata.pathScopedWellKnownURL(for: resource) {
            attempts.append("path-scoped protected-resource-metadata")
            if let meta = try? await resolveViaProtectedResource(metadataURLFetch: {
                try await ProtectedResourceMetadata.fetch(at: pathScoped, session: self.session)
            }) {
                return meta
            }
        }

        // 5. Direct auth-server metadata at the MCP origin (server is
        //    its own authorization server).
        attempts.append("origin auth-server metadata")
        if let meta = await AuthorizationServerMetadata.probeOrigin(resource, session: session) {
            return meta
        }

        throw AuthError.discoveryFailed(
            reason: "no OAuth metadata found for \(resource.absoluteString). Tried: \(attempts.joined(separator: ", ")). Set the Authorization server URL manually if the server uses a non-standard location."
        )
    }

    /// Issue an unauthenticated request to the MCP endpoint and, if it
    /// 401s with a `WWW-Authenticate: … resource_metadata="<url>"`
    /// header, return that URL. Best-effort; returns nil on anything else.
    private func probeResourceMetadataURL(resource: URL) async -> URL? {
        var request = URLRequest(url: resource)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        // A minimal MCP initialize-ish body; servers that gate on auth
        // 401 before parsing it, which is all we need.
        request.httpBody = Data("{}".utf8)
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 401,
              let header = http.value(forHTTPHeaderField: "WWW-Authenticate") else {
            return nil
        }
        return ProtectedResourceMetadata.resourceMetadataURL(fromWWWAuthenticate: header)
    }

    /// Resolve protected-resource-metadata via the supplied fetch, then
    /// chase its first authorization_servers entry to that server's
    /// metadata.
    private func resolveViaProtectedResource(
        metadataURLFetch: () async throws -> ProtectedResourceMetadata
    ) async throws -> AuthorizationServerMetadata {
        let prm = try await metadataURLFetch()
        guard let first = prm.authorizationServers.first else {
            throw AuthError.missingMetadata(field: "authorization_servers")
        }
        return try await fetchAuthorizationServerMetadata(first)
    }

    // MARK: - Metadata caching

    private func fetchAuthorizationServerMetadata(_ url: URL) async throws -> AuthorizationServerMetadata {
        if let cached = metadataCache[url] { return cached }
        let fresh = try await AuthorizationServerMetadata.fetch(
            authorizationServer: url,
            session: session
        )
        metadataCache[url] = fresh
        return fresh
    }

    // MARK: - Keychain I/O

    private func loadAccessToken(for serverID: MCPServerID) async throws -> String? {
        try await secretStore.secret(for: KeychainAccount.mcpAccessToken(serverID))
    }

    private func loadRefreshToken(for serverID: MCPServerID) async throws -> String? {
        try await secretStore.secret(for: KeychainAccount.mcpRefreshToken(serverID))
    }

    private func loadMetadata(for serverID: MCPServerID) async throws -> TokenMetadata? {
        guard let raw = try await secretStore.secret(for: KeychainAccount.mcpTokenMetadata(serverID)) else {
            return nil
        }
        return try? TokenMetadata.decode(raw)
    }

    private func persistTokens(
        serverID: MCPServerID,
        tokens: TokenResponse,
        metadata: TokenMetadata,
        fallbackRefreshToken: String? = nil
    ) async throws {
        try await secretStore.setSecret(tokens.accessToken, for: KeychainAccount.mcpAccessToken(serverID))
        if let refresh = tokens.refreshToken {
            try await secretStore.setSecret(refresh, for: KeychainAccount.mcpRefreshToken(serverID))
        } else if let fallback = fallbackRefreshToken {
            try await secretStore.setSecret(fallback, for: KeychainAccount.mcpRefreshToken(serverID))
        }
        let encoded = try metadata.encode()
        try await secretStore.setSecret(encoded, for: KeychainAccount.mcpTokenMetadata(serverID))
    }

    // MARK: - Helpers

    private static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = bytes.withUnsafeMutableBufferPointer {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func formURLEncoded(_ params: [String: String]) -> Data {
        let pairs = params.map { (k, v) in
            "\(percentEncoded(k))=\(percentEncoded(v))"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func percentEncoded(_ s: String) -> String {
        // application/x-www-form-urlencoded: encode every reserved
        // char per RFC 3986 §2.3 (unreserved chars only).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

#if canImport(AuthenticationServices)
private final class ContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    static let shared = ContextProvider()
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Must return a real on-screen NSWindow. A bare
        // `ASPresentationAnchor()` placeholder makes session.start()
        // silently no-op on macOS — which was part of the "nothing
        // happens" bug. Prefer key → main → any visible window. The
        // Settings window is always open when the Sign in button is
        // reachable, so a window will exist; the final non-visible
        // fallback only guards a degenerate state.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            if let key = app.keyWindow { return key }
            if let main = app.mainWindow { return main }
            if let visible = app.windows.first(where: { $0.isVisible }) { return visible }
            return app.windows.first ?? ASPresentationAnchor()
        }
    }
}
#endif

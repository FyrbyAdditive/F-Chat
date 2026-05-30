// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatMCP

@Suite("OAuth metadata + tokens", .serialized)
struct MetadataAndTokensTests {
    @Test func protectedResourceMetadataFetchAndParse() async throws {
        // ProtectedResourceMetadata.fetch rebases to
        // <scheme>://<host>/.well-known/oauth-protected-resource.
        // Stub against the rebased URL.
        let resource = URL(string: "https://stub-\(UUID().uuidString).test/mcp")!
        let wellKnown = ProtectedResourceMetadata.wellKnownURL(for: resource)
        let session = registerStub(at: wellKnown, response: .json([
            "resource": "https://api.example.com/mcp",
            "authorization_servers": ["https://auth.example.com"],
        ]))
        let result = try await ProtectedResourceMetadata.fetch(
            resource: resource,
            session: session
        )
        #expect(result.resource == "https://api.example.com/mcp")
        #expect(result.authorizationServers.map(\.absoluteString) == ["https://auth.example.com"])
    }

    @Test func protectedResourceMetadataMissingAuthServersThrows() async {
        let resource = URL(string: "https://stub-\(UUID().uuidString).test/mcp")!
        let wellKnown = ProtectedResourceMetadata.wellKnownURL(for: resource)
        let session = registerStub(at: wellKnown, response: .json([
            "resource": "https://api.example.com",
        ]))
        await #expect(throws: AuthError.self) {
            _ = try await ProtectedResourceMetadata.fetch(resource: resource, session: session)
        }
    }

    @Test func authorizationServerMetadataParsesRequiredFields() async throws {
        let authServer = URL(string: "https://stub-\(UUID().uuidString).test")!
        let wellKnown = AuthorizationServerMetadata.wellKnownURL(for: authServer)
        let session = registerStub(at: wellKnown, response: .json([
            "issuer": "https://auth.example.com",
            "authorization_endpoint": "https://auth.example.com/authorize",
            "token_endpoint": "https://auth.example.com/token",
            "registration_endpoint": "https://auth.example.com/register",
            "code_challenge_methods_supported": ["S256", "plain"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "scopes_supported": ["read", "write"],
        ]))
        let meta = try await AuthorizationServerMetadata.fetch(
            authorizationServer: authServer,
            session: session
        )
        #expect(meta.issuer == "https://auth.example.com")
        #expect(meta.authorizationEndpoint.absoluteString == "https://auth.example.com/authorize")
        #expect(meta.tokenEndpoint.absoluteString == "https://auth.example.com/token")
        #expect(meta.registrationEndpoint?.absoluteString == "https://auth.example.com/register")
        #expect(meta.supportsS256PKCE)
        #expect(meta.supportsAuthorizationCode)
        #expect(meta.supportsRefreshToken)
    }

    @Test func authorizationServerMetadataRejectsNonPublicEndpoint() async {
        // A hostile/MITM'd metadata doc that points the token endpoint at an
        // internal host must be rejected before we ever POST the bearer header.
        let wellKnown = URL(string: "https://stub-\(UUID().uuidString).test/.well-known/oauth-authorization-server")!
        let session = registerStub(at: wellKnown, response: .json([
            "issuer": "https://auth.example.com",
            "authorization_endpoint": "https://auth.example.com/authorize",
            "token_endpoint": "http://169.254.169.254/token",   // cloud metadata
        ]))
        await #expect(throws: AuthError.self) {
            _ = try await AuthorizationServerMetadata.fetchExact(wellKnown, session: session)
        }
    }

    @Test func dynamicClientRegistrationParsesResponse() async throws {
        // DCR posts to whatever URL we give it; no rebase logic.
        let endpoint = URL(string: "https://stub-\(UUID().uuidString).test/register")!
        let session = registerStub(at: endpoint, response: .json([
            "client_id": "abc-123",
            "client_secret": "shh",
            "registration_access_token": "ratt",
            "client_secret_expires_at": 0, // never expires per RFC 7591
        ]))
        let result = try await DynamicClientRegistration.register(
            at: endpoint,
            clientName: "F-Chat",
            redirectURIs: ["fchat://oauth/callback"],
            scope: "read write",
            session: session
        )
        #expect(result.clientID == "abc-123")
        #expect(result.clientSecret == "shh")
        #expect(result.registrationAccessToken == "ratt")
        #expect(result.clientSecretExpiresAt == nil)
    }

    @Test func tokenResponseParsesHappyPath() throws {
        let json = """
        {
            "access_token": "at-1",
            "token_type": "Bearer",
            "expires_in": 3600,
            "refresh_token": "rt-1",
            "scope": "read write"
        }
        """
        let resp = try TokenResponse.parse(Data(json.utf8))
        #expect(resp.accessToken == "at-1")
        #expect(resp.refreshToken == "rt-1")
        #expect(resp.expiresIn == 3600)
        #expect(resp.scope == "read write")
    }

    @Test func tokenResponseInvalidGrantSurfacesAsReAuthError() {
        let json = """
        { "error": "invalid_grant", "error_description": "refresh token expired" }
        """
        #expect(throws: AuthError.needsReAuthentication) {
            _ = try TokenResponse.parse(Data(json.utf8))
        }
    }

    @Test func tokenResponseMissingAccessTokenThrows() {
        // A token endpoint that returns 200 but no access_token must fail
        // closed, not yield an empty/garbage bearer.
        let json = #"{ "token_type": "Bearer", "expires_in": 3600 }"#
        #expect(throws: (any Error).self) {
            _ = try TokenResponse.parse(Data(json.utf8))
        }
    }

    @Test func tokenMetadataRoundTrips() throws {
        let original = TokenMetadata(
            tokenEndpoint: URL(string: "https://auth.example.com/token")!,
            clientID: "abc-123",
            clientSecret: "shh",
            registrationAccessToken: "ratt",
            scope: "read",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            resource: URL(string: "https://api.example.com/mcp")!
        )
        let encoded = try original.encode()
        let decoded = try TokenMetadata.decode(encoded)
        #expect(decoded == original)
    }
}

// MARK: - URLProtocol stub

fileprivate func registerStub(at url: URL, response: StubProtocol.Response) -> URLSession {
    StubProtocol.responses[url] = response
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

fileprivate final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case json([String: Any])
        case error(status: Int, body: String)
    }

    nonisolated(unsafe) static var responses: [URL: Response] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return responses[url] != nil
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let url = task.currentRequest?.url else { return false }
        return responses[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = Self.responses[url] else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        switch response {
        case .json(let body):
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            let resp = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let status, let body):
            let resp = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

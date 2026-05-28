import Testing
import Foundation
@testable import FChatMCP

@Suite("OAuth discovery helpers")
struct DiscoveryHelpersTests {
    @Test func wwwAuthenticateResourceMetadataQuoted() {
        let header = #"Bearer error="invalid_request", resource_metadata="https://api.example.com/.well-known/oauth-protected-resource""#
        let url = ProtectedResourceMetadata.resourceMetadataURL(fromWWWAuthenticate: header)
        #expect(url?.absoluteString == "https://api.example.com/.well-known/oauth-protected-resource")
    }

    @Test func wwwAuthenticateResourceMetadataFirstParam() {
        let header = #"Bearer resource_metadata="https://auth.test/meta", error="x""#
        let url = ProtectedResourceMetadata.resourceMetadataURL(fromWWWAuthenticate: header)
        #expect(url?.absoluteString == "https://auth.test/meta")
    }

    @Test func wwwAuthenticateNoResourceMetadataReturnsNil() {
        let header = #"Bearer error="invalid_token", error_description="expired""#
        #expect(ProtectedResourceMetadata.resourceMetadataURL(fromWWWAuthenticate: header) == nil)
    }

    @Test func pathScopedWellKnownInsertsResourcePath() {
        let resource = URL(string: "https://api.example.com/mcp/v1")!
        let url = ProtectedResourceMetadata.pathScopedWellKnownURL(for: resource)
        #expect(url?.absoluteString == "https://api.example.com/.well-known/oauth-protected-resource/mcp/v1")
    }

    @Test func pathScopedWellKnownNilForRootPath() {
        let resource = URL(string: "https://api.example.com")!
        #expect(ProtectedResourceMetadata.pathScopedWellKnownURL(for: resource) == nil)
        let rootSlash = URL(string: "https://api.example.com/")!
        #expect(ProtectedResourceMetadata.pathScopedWellKnownURL(for: rootSlash) == nil)
    }

    @Test func originWellKnownBuildsDocumentURL() {
        let origin = URL(string: "https://api.example.com/mcp")!
        let oauth = AuthorizationServerMetadata.wellKnownURL(for: origin, document: "oauth-authorization-server")
        #expect(oauth.absoluteString == "https://api.example.com/.well-known/oauth-authorization-server")
        let oidc = AuthorizationServerMetadata.wellKnownURL(for: origin, document: "openid-configuration")
        #expect(oidc.absoluteString == "https://api.example.com/.well-known/openid-configuration")
    }

    @Test func fetchAtExplicitURLParsesProtectedResource() async throws {
        let url = URL(string: "https://stub-\(UUID().uuidString).test/explicit-meta")!
        let session = registerStub(at: url, json: [
            "resource": "https://api.example.com/mcp",
            "authorization_servers": ["https://auth.example.com"],
        ])
        let result = try await ProtectedResourceMetadata.fetch(at: url, session: session)
        #expect(result.authorizationServers.map(\.absoluteString) == ["https://auth.example.com"])
    }

    @Test func probeOriginResolvesOAuthAuthorizationServer() async throws {
        let origin = URL(string: "https://stub-\(UUID().uuidString).test/mcp")!
        let wellKnown = AuthorizationServerMetadata.wellKnownURL(for: origin, document: "oauth-authorization-server")
        let session = registerStub(at: wellKnown, json: [
            "issuer": "https://stub.test",
            "authorization_endpoint": "https://stub.test/authorize",
            "token_endpoint": "https://stub.test/token",
            "code_challenge_methods_supported": ["S256"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
        ])
        let meta = await AuthorizationServerMetadata.probeOrigin(origin, session: session)
        #expect(meta?.tokenEndpoint.absoluteString == "https://stub.test/token")
        #expect(meta?.supportsS256PKCE == true)
    }
}

// MARK: - URLProtocol stub

fileprivate func registerStub(at url: URL, json: [String: Any]) -> URLSession {
    DiscoveryStubProtocol.responses[url] = json
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DiscoveryStubProtocol.self]
    return URLSession(configuration: config)
}

fileprivate final class DiscoveryStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [URL: [String: Any]] = [:]

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
        guard let url = request.url, let body = Self.responses[url] else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let resp = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

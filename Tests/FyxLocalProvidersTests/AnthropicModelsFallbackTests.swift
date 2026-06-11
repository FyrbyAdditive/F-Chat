// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalProviders
@testable import FyxLocalCore

/// Issue #2: DeepSeek's Anthropic-compatible gateway serves chat under
/// `…/anthropic/v1/*` but exposes `GET /models` only at the host root
/// (`https://api.deepseek.com/models`, OpenAI response shape). The provider
/// keeps the app's normal convention — endpoints append to the configured
/// base — and falls back to `scheme://host/models` when `{base}/models`
/// fails. Nothing here is DeepSeek-specific.
@Suite("Anthropic models host-root fallback")
struct AnthropicModelsFallbackTests {

    // MARK: - hostRootModelsURL

    @Test func subPathBaseYieldsHostRootModels() {
        let url = ProviderHTTP.hostRootModelsURL(from: URL(string: "https://api.deepseek.com/anthropic/v1")!)
        #expect(url?.absoluteString == "https://api.deepseek.com/models")
    }

    @Test func trailingSlashAndSingleSegmentAlsoResolve() {
        #expect(
            ProviderHTTP.hostRootModelsURL(from: URL(string: "https://api.deepseek.com/anthropic/")!)?.absoluteString
            == "https://api.deepseek.com/models"
        )
        #expect(
            ProviderHTTP.hostRootModelsURL(from: URL(string: "https://api.anthropic.com/v1")!)?.absoluteString
            == "https://api.anthropic.com/models"
        )
    }

    @Test func portIsPreserved() {
        let url = ProviderHTTP.hostRootModelsURL(from: URL(string: "https://gw.example.com:8443/anthropic/v1")!)
        #expect(url?.absoluteString == "https://gw.example.com:8443/models")
    }

    @Test func hostRootBaseHasNoDistinctFallback() {
        // `{base}/models` already IS the host-root URL — retrying would just
        // repeat the failed request.
        #expect(ProviderHTTP.hostRootModelsURL(from: URL(string: "https://api.example.com")!) == nil)
        #expect(ProviderHTTP.hostRootModelsURL(from: URL(string: "https://api.example.com/")!) == nil)
    }

    // MARK: - OpenAI-shape /models decodes via the Anthropic decoder

    @Test func openAIStyleModelsPayloadDecodes() throws {
        // DeepSeek's actual root /models response shape (from issue #2):
        // no display_name, no has_more/last_id — all optional in our decoder.
        let json = #"{"object":"list","data":[{"id":"deepseek-v4-flash","object":"model","owned_by":"deepseek"},{"id":"deepseek-v4-pro","object":"model","owned_by":"deepseek"}]}"#
        let (models, hasMore, lastID) = try AnthropicMessagesProvider.decodeModels(Data(json.utf8))
        #expect(models.map(\.id) == ["deepseek-v4-flash", "deepseek-v4-pro"])
        #expect(models[0].displayName == "deepseek-v4-flash")  // falls back to id
        #expect(hasMore == false)
        #expect(lastID == nil)
    }

    // MARK: - End-to-end: 404 at {base}/models → host-root retry

    @Test func primary404FallsBackToHostRoot() async throws {
        let id = ProviderID(rawValue: "deepseek-anthropic")
        let store = InMemorySecretStore()
        await store.setSecret("sk-test-123", for: KeychainAccount.providerAPIKey(id))

        let host = ModelsStub.uniqueHost()
        ModelsStub.set(host: host, path: "/anthropic/v1/models", status: 404, body: #"{"error":"not found"}"#)
        ModelsStub.set(host: host, path: "/models", status: 200, body: #"{"object":"list","data":[{"id":"deepseek-v4-flash","object":"model","owned_by":"deepseek"}]}"#)

        let provider = AnthropicMessagesProvider(
            id: id,
            baseURL: URL(string: "https://\(host)/anthropic/v1")!,
            session: ModelsStub.session(),
            secretStore: store
        )
        let models = try await provider.listModels()
        #expect(models.map(\.id) == ["deepseek-v4-flash"])

        // The fallback request carried BOTH auth schemes: the gateway's root
        // surface is usually its OpenAI side (Bearer), while x-api-key +
        // anthropic-version ride along from the provider's normal auth.
        let fallbackRequest = ModelsStub.request(host: host, path: "/models")
        #expect(fallbackRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
        #expect(fallbackRequest?.value(forHTTPHeaderField: "x-api-key") == "sk-test-123")
    }

    @Test func workingPrimaryNeverTouchesHostRoot() async throws {
        let id = ProviderID(rawValue: "anthropic-proper")
        let host = ModelsStub.uniqueHost()
        ModelsStub.set(host: host, path: "/v1/models", status: 200, body: #"{"data":[{"type":"model","id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5"}],"has_more":false}"#)

        let provider = AnthropicMessagesProvider(
            id: id,
            baseURL: URL(string: "https://\(host)/v1")!,
            session: ModelsStub.session(),
            secretStore: InMemorySecretStore()
        )
        let models = try await provider.listModels()
        #expect(models.map(\.id) == ["claude-sonnet-4-5"])
        #expect(ModelsStub.request(host: host, path: "/models") == nil)  // no fallback fired
    }

    @Test func bothFailingRethrowsThePrimaryError() async {
        let id = ProviderID(rawValue: "broken-gateway")
        let host = ModelsStub.uniqueHost()
        ModelsStub.set(host: host, path: "/anthropic/v1/models", status: 404, body: "primary-not-found")
        ModelsStub.set(host: host, path: "/models", status: 500, body: "root-broken")

        let provider = AnthropicMessagesProvider(
            id: id,
            baseURL: URL(string: "https://\(host)/anthropic/v1")!,
            session: ModelsStub.session(),
            secretStore: InMemorySecretStore()
        )
        do {
            _ = try await provider.listModels()
            Issue.record("expected throw")
        } catch let ProviderError.httpStatus(status, body) {
            // The surfaced error must point at the URL the user configured,
            // not the speculative host-root retry.
            #expect(status == 404)
            #expect(body.contains("primary-not-found"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - URLProtocol stub

/// Maps `host + path` (query ignored — the provider appends `?limit=1000`) to
/// canned responses and records the requests it served, so tests can assert
/// which endpoints were hit and with which headers. Each test uses a unique
/// fake host, so parallel tests never share or clobber entries (the same
/// pattern as StreamResilienceTests' StreamStub).
private final class ModelsStub: URLProtocol, @unchecked Sendable {
    struct Canned { let status: Int; let body: String }

    nonisolated(unsafe) private static var responses: [String: Canned] = [:]
    nonisolated(unsafe) private static var served: [String: URLRequest] = [:]
    private static let lock = NSLock()

    static func uniqueHost() -> String { "stub-\(UUID().uuidString.lowercased()).fallback.test" }

    private static func key(_ host: String, _ path: String) -> String { "\(host)|\(path)" }

    static func set(host: String, path: String, status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        responses[key(host, path)] = Canned(status: status, body: body)
    }

    static func request(host: String, path: String) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return served[key(host, path)]
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelsStub.self]
        return URLSession(configuration: config)
    }

    private static func canned(for url: URL?) -> Canned? {
        guard let url, let host = url.host else { return nil }
        lock.lock(); defer { lock.unlock() }
        return responses[key(host, url.path)]
    }

    override class func canInit(with request: URLRequest) -> Bool { canned(for: request.url) != nil }
    override class func canInit(with task: URLSessionTask) -> Bool { canned(for: task.currentRequest?.url) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let canned = Self.canned(for: url) else {
            client?.urlProtocolDidFinishLoading(self); return
        }
        Self.lock.lock(); Self.served[Self.key(host, url.path)] = request; Self.lock.unlock()
        let resp = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(canned.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

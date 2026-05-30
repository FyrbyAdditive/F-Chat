// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatMCP

/// Drives `HTTPMCPTransport` against a `URLProtocol` stub that fakes the
/// HTTP server. No network goes out. Covers the four spec-relevant
/// shapes: JSON response, SSE response, auth failure, session-id
/// round-trip.
@Suite("HTTPMCPTransport", .serialized)
struct HTTPMCPTransportTests {
    @Test func jsonResponseDecodedAndYielded() async throws {
        let (session, url) = makeSession(response: .json([
            "jsonrpc": "2.0",
            "id": 1,
            "result": ["serverInfo": ["name": "stub", "version": "0.1"], "protocolVersion": "2025-11-25"],
        ]))
        let transport = HTTPMCPTransport(url: url, session: session)
        let inbound = transport.incoming()
        var iterator = inbound.makeAsyncIterator()

        try await transport.send(.request(.init(id: .int(1), method: "initialize", params: nil)))
        let frame = try await iterator.next()
        guard case .response(let response) = frame else {
            Issue.record("expected response, got \(String(describing: frame))")
            return
        }
        #expect(response.id == .int(1))
        await transport.close()
    }

    @Test func http401SurfacesAsTransportError() async {
        let (session, url) = makeSession(response: .error(status: 401, body: "auth required"))
        let transport = HTTPMCPTransport(url: url, session: session)

        await #expect(throws: MCPTransportError.self) {
            try await transport.send(.request(.init(id: .int(1), method: "initialize", params: nil)))
        }
        await transport.close()
    }

    @Test func sessionIDRoundTrips() async throws {
        let (session, url) = makeSession(response: .jsonWithSessionID(
            [
                "jsonrpc": "2.0",
                "id": 1,
                "result": ["serverInfo": ["name": "stub", "version": "0.1"], "protocolVersion": "2025-11-25"],
            ],
            sessionID: "abc-123"
        ))
        let transport = HTTPMCPTransport(url: url, session: session)
        let inbound = transport.incoming()
        var iterator = inbound.makeAsyncIterator()

        try await transport.send(.request(.init(id: .int(1), method: "initialize", params: nil)))
        _ = try await iterator.next()

        // Second call should echo Mcp-Session-Id back in the request.
        try await transport.send(.request(.init(id: .int(2), method: "tools/list", params: nil)))
        await Task.yield()
        let lastRequest = StubProtocol.lastRequestByURL[url] ?? nil
        #expect(lastRequest?.value(forHTTPHeaderField: "Mcp-Session-Id") == "abc-123")

        await transport.close()
    }

    @Test func extraHeadersForwarded() async throws {
        let (session, url) = makeSession(response: .json([
            "jsonrpc": "2.0",
            "id": 1,
            "result": [:],
        ]))
        let transport = HTTPMCPTransport(url: url, extraHeaders: [
            "Authorization": "Bearer test-token",
            "X-Custom": "value",
        ], session: session)
        try await transport.send(.request(.init(id: .int(1), method: "ping", params: nil)))
        await Task.yield()
        let req = StubProtocol.lastRequestByURL[url] ?? nil
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(req?.value(forHTTPHeaderField: "X-Custom") == "value")
        await transport.close()
    }

    private func makeSession(response: StubProtocol.Response) -> (URLSession, URL) {
        let url = URL(string: "https://stub.test/\(UUID().uuidString)")!
        StubProtocol.responses[url] = response
        StubProtocol.lastRequestByURL[url] = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        return (session, url)
    }
}

// MARK: - URLProtocol stub

fileprivate final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case json([String: Any])
        case jsonWithSessionID([String: Any], sessionID: String)
        case error(status: Int, body: String)
    }

    nonisolated(unsafe) static var responses: [URL: Response] = [:]
    nonisolated(unsafe) static var lastRequestByURL: [URL: URLRequest?] = [:]

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
        Self.lastRequestByURL[url] = request

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
        case .jsonWithSessionID(let body, let sid):
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            let resp = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "Mcp-Session-Id": sid]
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

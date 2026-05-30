// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders

/// M3: one malformed event in a stream must not kill the whole turn — it's
/// logged + skipped and the surrounding good events still arrive. An entirely
/// undecodable stream surfaces a `.responseError`, not a silent blank.
@Suite("Stream decode resilience", .serialized)
struct StreamResilienceTests {

    @Test func malformedEventIsSkippedAndGoodEventsSurvive() async throws {
        // Three SSE frames; the middle one decodes to a thrown error.
        let body = """
        data: good-1

        data: BOOM

        data: good-2

        data: [DONE]

        """
        let url = StreamStub.uniqueURL()
        let session = StreamStub.session(url: url, body: body)
        let stream = streamSSE(
            session: session,
            makeRequest: { URLRequest(url: url) },
            makeDecode: {
                { sse in
                    let d = sse.data
                    if d.isEmpty { return nil }
                    if d == "BOOM" { throw StreamStubError.boom }
                    return .textDelta(itemID: "x", delta: d)
                }
            },
            isDone: { $0.data == "[DONE]" }
        )

        var deltas: [String] = []
        for try await event in stream {
            if case .textDelta(_, let delta) = event { deltas.append(delta) }
        }
        #expect(deltas == ["good-1", "good-2"])   // BOOM skipped, stream survived
    }

    @Test func allUndecodableSurfacesResponseError() async throws {
        let body = "data: BOOM\n\ndata: [DONE]\n\n"
        let url = StreamStub.uniqueURL()
        let session = StreamStub.session(url: url, body: body)
        let stream = streamSSE(
            session: session,
            makeRequest: { URLRequest(url: url) },
            makeDecode: { { _ in throw StreamStubError.boom } },
            isDone: { $0.data == "[DONE]" }
        )
        var sawError = false
        for try await event in stream {
            if case .responseError = event { sawError = true }
        }
        #expect(sawError)
    }
}

private enum StreamStubError: Error { case boom }

private final class StreamStub: URLProtocol, @unchecked Sendable {
    // Bodies keyed by URL behind a lock so parallel tests (each with its own
    // unique URL) never race on shared mutable state.
    nonisolated(unsafe) private static var bodies: [URL: String] = [:]
    private static let lock = NSLock()

    static func uniqueURL() -> URL { URL(string: "https://stream.stub.test/\(UUID().uuidString)")! }

    static func session(url: URL, body: String) -> URLSession {
        lock.lock(); bodies[url] = body; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamStub.self]
        return URLSession(configuration: config)
    }

    private static func body(for url: URL?) -> String? {
        guard let url else { return nil }
        lock.lock(); defer { lock.unlock() }
        return bodies[url]
    }

    override class func canInit(with request: URLRequest) -> Bool { body(for: request.url) != nil }
    override class func canInit(with task: URLSessionTask) -> Bool { body(for: task.currentRequest?.url) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let body = Self.body(for: url) else {
            client?.urlProtocolDidFinishLoading(self); return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

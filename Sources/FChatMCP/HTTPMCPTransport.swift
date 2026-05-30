// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// Streamable HTTP MCP transport (MCP 2025-11-25 spec, without OAuth).
///
/// Wire shape:
/// - Every `send(_:)` does an HTTP POST of one JSON-RPC frame to `url`.
/// - The response is either:
///     * `Content-Type: application/json` — a single JSON-RPC frame
///       (response or notification). Decoded and yielded on `incoming()`.
///     * `Content-Type: text/event-stream` — zero or more `data:`-prefixed
///       JSON-RPC frames over SSE. Each line is decoded and yielded.
/// - The server may issue an `Mcp-Session-Id` header in the initialize
///   response; we echo it on every subsequent request.
///
/// Auth is header-based only. If the server requires auth, the user must
/// set an `Authorization` (or similar) header in the server's HTTPConfig.
/// OAuth 2.1 (PKCE / DCR / RFC 8707 + Keychain token storage) is
/// deliberately out of scope for this pass.
public actor HTTPMCPTransport: MCPTransport {
    public let url: URL
    public let extraHeaders: [String: String]

    private let session: URLSession
    private var mcpSessionID: String?
    private var inboundContinuation: AsyncThrowingStream<JSONRPCFrame, Error>.Continuation?
    private let inboundStream: AsyncThrowingStream<JSONRPCFrame, Error>
    private var closed = false
    /// Optional callback supplied by the registry when this transport is
    /// gated by OAuth. Returns a fresh "Bearer <token>" string the
    /// transport should use as the Authorization header. Called on 401
    /// to drive a transparent refresh + retry.
    public typealias AuthorizationRefresher = @Sendable () async throws -> String
    private var authorizationRefresher: AuthorizationRefresher?
    /// Cached Authorization header value, replaced on every successful
    /// refresh. Takes precedence over any "Authorization" key in
    /// `extraHeaders`.
    private var currentAuthorization: String?

    public init(url: URL, extraHeaders: [String: String] = [:], session: URLSession? = nil) {
        self.url = url
        self.extraHeaders = extraHeaders
        // If the caller pre-set an Authorization header, treat it as
        // the initial "current" token so OAuth refresh paths see the
        // bearer token immediately.
        self.currentAuthorization = extraHeaders["Authorization"]
        if let session {
            self.session = session
        } else {
            // Per-instance URLSession so an `invalidateAndCancel` in close()
            // tears down any in-flight long-lived SSE streams cleanly. The SSRF
            // guard refuses redirects to non-public hosts (the Authorization
            // header must not leak to an internal address).
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            self.session = SSRFGuardingSessionDelegate.makeSession(configuration: config)
        }

        var c: AsyncThrowingStream<JSONRPCFrame, Error>.Continuation!
        self.inboundStream = AsyncThrowingStream<JSONRPCFrame, Error> { cont in
            c = cont
        }
        self.inboundContinuation = c
    }

    /// Install a refresh callback. When `send()` receives an HTTP 401
    /// and a callback is set, the callback is invoked, the returned
    /// Authorization value replaces the cached one, and the request is
    /// retried exactly once.
    public func setAuthorizationRefresher(_ block: @escaping AuthorizationRefresher) {
        self.authorizationRefresher = block
    }

    public func send(_ frame: JSONRPCFrame) async throws {
        guard !closed else { throw MCPTransportError.closed }

        let bodyData = try JSONRPCCodec.encode(frame)
        do {
            try await sendOnce(bodyData: bodyData)
        } catch MCPTransportError.ioError(let message) where message.hasPrefix("HTTP 401") {
            // Auth-refresh + single retry path. If the refresher fires
            // successfully but the second attempt also 401s, bubble it
            // up — we don't loop.
            guard let refresher = authorizationRefresher else { throw MCPTransportError.ioError(message) }
            let fresh: String
            do { fresh = try await refresher() }
            catch { throw MCPTransportError.ioError("auth refresh failed: \(error)") }
            currentAuthorization = fresh
            try await sendOnce(bodyData: bodyData)
        }
    }

    /// Single-attempt POST; does not retry on auth failure. The retry
    /// loop lives in `send`.
    private func sendOnce(bodyData: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Servers advertise SSE via this Accept header — clients that ask
        // for both get the streaming response when the server prefers it.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in extraHeaders where k.lowercased() != "authorization" {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let auth = currentAuthorization {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let id = mcpSessionID {
            request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPTransportError.ioError("non-HTTP response")
        }

        // The server may issue or rotate the session id here. Persist it
        // for subsequent requests.
        if let issued = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !issued.isEmpty {
            mcpSessionID = issued
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = await readAllBytes(bytes)
            let snippet = body.isEmpty ? "" : ": \(String(data: body, encoding: .utf8)?.prefix(200) ?? "")"
            throw MCPTransportError.ioError("HTTP \(http.statusCode)\(snippet)")
        }

        // Notifications return 202 Accepted with no body — nothing to
        // decode or yield; just return.
        if http.statusCode == 202 {
            return
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            // Spawn a detached task to drain the SSE stream and yield
            // frames as they arrive. Doesn't block this `send` call —
            // the caller's response continuation is already registered
            // in MCPClient.pending.
            Task { [weak self] in
                await self?.consumeSSE(bytes)
            }
            return
        }

        if contentType.contains("application/json") || contentType.isEmpty {
            let body = await readAllBytes(bytes)
            if body.isEmpty { return }
            let decoded = try JSONRPCCodec.decode(body)
            inboundContinuation?.yield(decoded)
            return
        }

        throw MCPTransportError.protocolError("unsupported Content-Type: \(contentType)")
    }

    nonisolated public func incoming() -> AsyncThrowingStream<JSONRPCFrame, Error> {
        inboundStream
    }

    public func close() async {
        closed = true
        inboundContinuation?.finish()
        session.invalidateAndCancel()
    }

    // MARK: - SSE parsing

    /// Drains an SSE byte stream, decoding each `data:` block as a single
    /// JSON-RPC frame and yielding it onto the inbound continuation.
    /// Stops cleanly when the stream ends or an error surfaces.
    private func consumeSSE(_ bytes: URLSession.AsyncBytes) async {
        var dataBuffer = Data()
        do {
            for try await line in bytes.lines {
                if line.isEmpty {
                    // Blank line = end of event. Decode whatever's
                    // accumulated and yield it.
                    if !dataBuffer.isEmpty {
                        if let frame = try? JSONRPCCodec.decode(dataBuffer) {
                            inboundContinuation?.yield(frame)
                        }
                        dataBuffer.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                if line.hasPrefix(":") {
                    // SSE comment — keep-alive. Skip.
                    continue
                }
                if line.hasPrefix("data:") {
                    var payload = String(line.dropFirst(5))
                    if payload.hasPrefix(" ") { payload.removeFirst() }
                    if !dataBuffer.isEmpty { dataBuffer.append(UInt8(ascii: "\n")) }
                    dataBuffer.append(contentsOf: payload.utf8)
                }
                // Ignored: `event:`, `id:`, `retry:` — MCP over SSE
                // doesn't currently differentiate event types.
            }
            // Stream closed cleanly; flush any trailing event without a
            // terminating blank line.
            if !dataBuffer.isEmpty, let frame = try? JSONRPCCodec.decode(dataBuffer) {
                inboundContinuation?.yield(frame)
            }
        } catch {
            inboundContinuation?.finish(throwing: error)
        }
    }

    private func readAllBytes(_ bytes: URLSession.AsyncBytes) async -> Data {
        var buffer = Data()
        do {
            for try await byte in bytes {
                buffer.append(byte)
            }
        } catch {
            // Body read failed; return what we have so the caller can
            // surface a partial error message.
        }
        return buffer
    }
}

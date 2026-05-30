// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// Shared HTTP/streaming plumbing used by every `LLMProvider`. The
/// provider-specific parts (endpoint path, auth headers, request body encoding,
/// and the wire→`StreamEvent` decoder) stay in each provider; only the
/// identical boilerplate lives here.
enum ProviderHTTP {
    /// Throw `ProviderError.httpStatus` for a non-2xx response. Used by the
    /// non-streaming calls (`listModels`, `embed`).
    static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: body, encoding: .utf8) ?? "<binary>"
            throw ProviderError.httpStatus(http.statusCode, body: text)
        }
    }

    /// Decode an OpenAI-style embeddings response (`{ data: [{ index, embedding }] }`),
    /// sorted by index. The wire shape is the de-facto standard, so both
    /// providers share it.
    static func decodeEmbeddings(_ data: Data, expectedCount: Int) throws -> [[Float]] {
        struct R: Decodable {
            struct Entry: Decodable {
                let index: Int
                let embedding: [Float]
            }
            let data: [Entry]
        }
        let parsed = try JSONDecoder().decode(R.self, from: data)
        let sorted = parsed.data.sorted { $0.index < $1.index }
        guard sorted.count == expectedCount else {
            throw ProviderError.malformedResponse("embeddings count mismatch: got \(sorted.count) expected \(expectedCount)")
        }
        return sorted.map { $0.embedding }
    }
}

/// Drive a streaming SSE chat request and surface decoded `StreamEvent`s.
///
/// The caller builds a fully-formed `URLRequest` (provider-specific endpoint,
/// auth, headers, and JSON body) and supplies the event `decode` closure. This
/// helper owns the identical parts: launching the byte stream, the non-2xx
/// status check, the newline-buffered byte drain through `SSEParser`, decode +
/// yield, and the terminal `.completed`.
///
/// `isDone` lets a provider terminate early on a sentinel frame — OpenAI ends
/// its stream with a literal `data: [DONE]`; Anthropic has no sentinel (it
/// ends on its own `message_stop` event, so it uses the default that never
/// matches and the stream completes when the byte stream closes).
/// Build and drive a streaming SSE chat request end to end.
///
/// Everything runs inside the single `Task` this spawns, so the
/// provider-specific pieces never cross an isolation boundary:
/// - `makeRequest` builds the fully-formed `URLRequest` (endpoint, auth from
///   the keychain, headers, JSON body) — it's `async` because auth reads the
///   keychain.
/// - `makeDecode` builds the per-stream, stateful (non-`Sendable`) event
///   decoder; it stays task-local.
/// - `isDone` lets a provider terminate early on a sentinel frame (OpenAI's
///   `[DONE]`); the default never matches (Anthropic ends on `message_stop`).
func streamSSE(
    session: URLSession,
    makeRequest: @escaping @Sendable () async throws -> URLRequest,
    makeDecode: @escaping @Sendable () -> (SSEEvent) throws -> StreamEvent?,
    isDone: @escaping @Sendable (SSEEvent) -> Bool = { _ in false }
) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let request = try await makeRequest()
                let decode = makeDecode()
                try await runSSEStream(
                    request: request,
                    session: session,
                    decode: decode,
                    isDone: isDone,
                    into: continuation
                )
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func runSSEStream(
    request: URLRequest,
    session: URLSession,
    decode: (SSEEvent) throws -> StreamEvent?,
    isDone: (SSEEvent) -> Bool,
    into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
) async throws {
    let (bytes, response) = try await session.bytes(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        var lines: [String] = []
        for try await line in bytes.lines { lines.append(line) }
        throw ProviderError.httpStatus(http.statusCode, body: lines.joined(separator: "\n"))
    }

    // Drain the raw byte stream and feed the parser at each newline boundary.
    // We iterate `bytes` directly (NOT `bytes.lines`): `.lines` adds its own
    // buffering layer that can delay delivery of partial SSE frames, which
    // visibly stalls incremental streaming (e.g. live "thinking" text). The
    // raw byte iterator flushes a region to the parser the instant its
    // terminating "\n" arrives, preserving real-time streaming. We accumulate
    // into a [UInt8] and decode each region once per line (not per byte).
    let parser = SSEParser()
    var lineBuffer: [UInt8] = []
    for try await byte in bytes {
        try Task.checkCancellation()
        lineBuffer.append(byte)
        if byte == UInt8(ascii: "\n") {
            if let chunk = String(bytes: lineBuffer, encoding: .utf8) {
                lineBuffer.removeAll(keepingCapacity: true)
                for sse in parser.feed(chunk) {
                    if isDone(sse) {
                        continuation.yield(.completed)
                        return
                    }
                    if let event = try decode(sse) {
                        continuation.yield(event)
                    }
                }
            }
        }
    }
    if !lineBuffer.isEmpty, let chunk = String(bytes: lineBuffer, encoding: .utf8) {
        for sse in parser.feed(chunk) {
            if isDone(sse) { continuation.yield(.completed); return }
            if let event = try decode(sse) { continuation.yield(event) }
        }
    }
    for sse in parser.finish() {
        if let event = try decode(sse) {
            continuation.yield(event)
        }
    }
    continuation.yield(.completed)
}

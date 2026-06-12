// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

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

    /// Host-root fallback URL for model listing. Some API-compatible gateways
    /// serve chat under a sub-path but expose `GET /models` only at the host
    /// root — DeepSeek's Anthropic-compatible endpoint is the canonical case:
    /// chat lives at `…/anthropic/v1/messages`, but models live at
    /// `https://api.deepseek.com/models`, *below* the documented base.
    /// Returns `scheme://host[:port]/models`, or nil when the configured base
    /// has no sub-path (the fallback would just repeat the failed request).
    static func hostRootModelsURL(from base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              components.host != nil else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !basePath.isEmpty else { return nil }
        components.path = "/models"
        components.query = nil
        return components.url
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
///   decoder; it stays task-local. A decoder returns *all* events a frame
///   yields, in order — most frames carry one signal, but Chat Completions
///   chunks can carry several (e.g. a finish marker completing text *and*
///   multiple parallel tool calls at once).
/// - `isDone` lets a provider terminate early on a sentinel frame (OpenAI's
///   `[DONE]`); the default never matches (Anthropic ends on `message_stop`).
func streamSSE(
    session: URLSession,
    makeRequest: @escaping @Sendable () async throws -> URLRequest,
    makeDecode: @escaping @Sendable () -> (SSEEvent) throws -> [StreamEvent],
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

/// Drive a streaming NDJSON chat request end to end — the newline-delimited-
/// JSON sibling of `streamSSE`, with identical semantics (single task,
/// per-line decode returning all events, malformed-line skip, "no usable
/// event" terminal error, cancellation via onTermination). Used by Ollama's
/// native API, which streams one JSON object per line and ends with a
/// `"done":true` object followed by EOF — there is no SSE framing and no
/// `[DONE]` sentinel.
func streamNDJSON(
    session: URLSession,
    makeRequest: @escaping @Sendable () async throws -> URLRequest,
    makeDecode: @escaping @Sendable () -> (String) throws -> [StreamEvent]
) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                let request = try await makeRequest()
                let decode = makeDecode()
                try await runNDJSONStream(
                    request: request,
                    session: session,
                    decode: decode,
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

private func runNDJSONStream(
    request: URLRequest,
    session: URLSession,
    decode: (String) throws -> [StreamEvent],
    into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
) async throws {
    let (bytes, response) = try await session.bytes(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        var lines: [String] = []
        for try await line in bytes.lines { lines.append(line) }
        throw ProviderError.httpStatus(http.statusCode, body: lines.joined(separator: "\n"))
    }

    var lineBuffer: [UInt8] = []
    var yieldedAny = false

    // Decode one NDJSON line, tolerating a single malformed line: log + skip
    // and keep the stream alive rather than failing the whole turn.
    func handle(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            for event in try decode(trimmed) {
                continuation.yield(event)
                yieldedAny = true
            }
        } catch {
            FileHandle.standardError.write(Data("[FyxLocal] skipped malformed NDJSON line: \(error)\n".utf8))
        }
    }

    // Drain raw bytes and flush a line to the decoder the instant its "\n"
    // arrives — same real-time rationale as runSSEStream (`.lines` buffers).
    for try await byte in bytes {
        try Task.checkCancellation()
        lineBuffer.append(byte)
        if byte == UInt8(ascii: "\n") {
            if let line = String(bytes: lineBuffer, encoding: .utf8) {
                lineBuffer.removeAll(keepingCapacity: true)
                handle(line)
            }
        }
    }
    if !lineBuffer.isEmpty, let line = String(bytes: lineBuffer, encoding: .utf8) {
        handle(line)
    }
    if !yieldedAny {
        continuation.yield(.responseError(message: "The provider returned no readable response.", code: nil))
    }
    continuation.yield(.completed)
}

private func runSSEStream(
    request: URLRequest,
    session: URLSession,
    decode: (SSEEvent) throws -> [StreamEvent],
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
    var yieldedAny = false

    // Decode one SSE frame, tolerating a single malformed event: log + skip it
    // and keep the stream alive rather than throwing out of the whole turn (a
    // provider can emit one bad event in a long stream). Returns true on a
    // terminal `[DONE]`.
    func handle(_ sse: SSEEvent) -> Bool {
        if isDone(sse) { return true }
        do {
            for event in try decode(sse) {
                continuation.yield(event)
                yieldedAny = true
            }
        } catch {
            FileHandle.standardError.write(Data("[FyxLocal] skipped malformed stream event: \(error)\n".utf8))
        }
        return false
    }
    // Single terminal path: if the whole stream produced no usable event,
    // surface a clear error instead of a silent blank reply, then complete.
    func finishStream() {
        if !yieldedAny {
            continuation.yield(.responseError(message: "The provider returned no readable response.", code: nil))
        }
        continuation.yield(.completed)
    }

    for try await byte in bytes {
        try Task.checkCancellation()
        lineBuffer.append(byte)
        if byte == UInt8(ascii: "\n") {
            if let chunk = String(bytes: lineBuffer, encoding: .utf8) {
                lineBuffer.removeAll(keepingCapacity: true)
                for sse in parser.feed(chunk) where handle(sse) {
                    finishStream(); return
                }
            }
        }
    }
    if !lineBuffer.isEmpty, let chunk = String(bytes: lineBuffer, encoding: .utf8) {
        for sse in parser.feed(chunk) where handle(sse) {
            finishStream(); return
        }
    }
    for sse in parser.finish() where handle(sse) {
        finishStream(); return
    }
    finishStream()
}

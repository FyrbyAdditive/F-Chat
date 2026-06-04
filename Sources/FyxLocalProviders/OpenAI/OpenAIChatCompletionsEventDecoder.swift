// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// Decodes streamed OpenAI **Chat Completions** SSE chunks into `StreamEvent`.
///
/// Each `data:` line is a chunk like
/// `{"id":…,"choices":[{"delta":{"content":"…"},"finish_reason":null}],"usage":null}`.
/// The decoder is stateful (one instance per stream): it emits a
/// `responseStarted` on the first chunk, `textDelta`/`reasoningSummaryDelta`
/// as content arrives, accumulates assistant text + streamed tool-call fragments,
/// and emits the matching `textCompleted` / `toolCallCompleted` when a chunk
/// carries a `finish_reason`. A trailing usage-only chunk (from
/// `stream_options.include_usage`) becomes `.usage`. `[DONE]` is handled by the
/// streamer's `isDone`; it never reaches here.
///
/// `decode` returns a single event per chunk (the contract). Real Chat
/// Completions chunks carry one signal each — a content delta, a tool-call
/// fragment, a finish marker, or usage — so this maps cleanly.
public final class OpenAIChatCompletionsEventDecoder {
    private var responseID: String?
    private var startedEmitted = false
    private let itemID = UUID().uuidString   // synthetic; CC has no per-text item id
    private var accumulatedText = ""

    // Streamed tool calls, keyed by their `index` in delta.tool_calls.
    private struct ToolCallAccum { var id: String; var name: String; var args: String }
    private var toolCalls: [Int: ToolCallAccum] = [:]
    private var toolCallOrder: [Int] = []

    public init() {}

    public func decode(_ sse: SSEEvent) throws -> StreamEvent? {
        guard let data = sse.data.data(using: .utf8) else { return nil }
        let chunk: Chunk
        do {
            chunk = try JSONDecoder().decode(Chunk.self, from: data)
        } catch {
            // Unknown/empty chunk — ignore rather than fail the stream.
            return nil
        }

        let choice = chunk.choices?.first

        // First chunk → responseStarted (with the chunk id when present). If it
        // also carries content (some servers put text in the opener), accumulate
        // it so the final textCompleted isn't missing that sliver — we just emit
        // the start event for this chunk; the text still arrives at completion.
        if !startedEmitted {
            startedEmitted = true
            responseID = chunk.id
            if let content = choice?.delta?.content { accumulatedText += content }
            return .responseStarted(id: chunk.id ?? UUID().uuidString)
        }

        // Tool-call fragments: accumulate; emit started when first identified.
        if let tcs = choice?.delta?.tool_calls, !tcs.isEmpty {
            // A chunk usually carries one fragment; if more, process in order
            // and return the first meaningful event (rare in practice).
            var firstEvent: StreamEvent?
            for tc in tcs {
                let idx = tc.index ?? 0
                let isNew = toolCalls[idx] == nil
                var accum = toolCalls[idx] ?? ToolCallAccum(id: "", name: "", args: "")
                if let id = tc.id { accum.id = id }
                if let name = tc.function?.name { accum.name = name }
                if let args = tc.function?.arguments { accum.args += args }
                toolCalls[idx] = accum
                if isNew { toolCallOrder.append(idx) }
                let started = isNew && !accum.id.isEmpty
                let event: StreamEvent = started
                    ? .toolCallStarted(itemID: "\(idx)", callID: accum.id, name: accum.name)
                    : .toolCallArgumentsDelta(itemID: "\(idx)", callID: accum.id, delta: tc.function?.arguments ?? "")
                if firstEvent == nil { firstEvent = event }
            }
            return firstEvent
        }

        // Reasoning content (reasoning models on Chat Completions). Servers vary:
        // OpenAI/DeepSeek use `reasoning_content`; vLLM/stepfun stream it as
        // `reasoning`. Accept either.
        if let rc = (choice?.delta?.reasoning_content ?? choice?.delta?.reasoning), !rc.isEmpty {
            return .reasoningSummaryDelta(itemID: itemID, delta: rc)
        }

        // Normal text content.
        if let content = choice?.delta?.content, !content.isEmpty {
            accumulatedText += content
            return .textDelta(itemID: itemID, delta: content)
        }

        // Finish marker → complete whatever was being produced.
        if let reason = choice?.finish_reason {
            if reason == "tool_calls" {
                // Emit completion for the (first) accumulated tool call.
                if let idx = toolCallOrder.first, let accum = toolCalls[idx] {
                    return .toolCallCompleted(
                        itemID: "\(idx)", callID: accum.id, name: accum.name,
                        arguments: accum.args.isEmpty ? "{}" : accum.args
                    )
                }
            }
            // stop / length / content_filter → text done.
            if !accumulatedText.isEmpty {
                return .textCompleted(itemID: itemID, fullText: accumulatedText)
            }
        }

        // Trailing usage-only chunk (choices empty, usage present).
        if let u = chunk.usage {
            return .usage(u.toUsageInfo())
        }

        // Top-level error object.
        if let err = chunk.error {
            return .responseError(message: err.message, code: err.code)
        }

        return nil
    }

    // MARK: - Payloads

    private struct Chunk: Decodable {
        let id: String?
        let choices: [Choice]?
        let usage: Usage?
        let error: ErrorObj?
    }

    private struct Choice: Decodable {
        let delta: Delta?
        let finish_reason: String?
    }

    private struct Delta: Decodable {
        let content: String?
        let reasoning_content: String?
        let reasoning: String?   // vLLM / stepfun stream reasoning under this key
        let tool_calls: [ToolCallDelta]?
    }

    private struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let function: Fn?
        struct Fn: Decodable {
            let name: String?
            let arguments: String?
        }
    }

    private struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let prompt_tokens_details: Details?
        struct Details: Decodable { let cached_tokens: Int? }

        func toUsageInfo() -> UsageInfo {
            UsageInfo(
                inputTokens: prompt_tokens ?? 0,
                outputTokens: completion_tokens ?? 0,
                reasoningTokens: nil,
                cachedInputTokens: prompt_tokens_details?.cached_tokens
            )
        }
    }

    private struct ErrorObj: Decodable {
        let message: String
        let code: String?
    }
}

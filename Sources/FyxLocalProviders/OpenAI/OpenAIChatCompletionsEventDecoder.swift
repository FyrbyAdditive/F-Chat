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
/// `decode` returns *all* events a chunk yields, in order. Most chunks carry a
/// single signal, but several genuinely carry more than one: the opening chunk
/// can double as the first content delta, a tool-call fragment can both start a
/// call and carry its first arguments slice, and a `finish_reason:"tool_calls"`
/// marker completes *every* accumulated call — parallel tool calls are the
/// reason this can't be a one-event contract.
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

    public func decode(_ sse: SSEEvent) throws -> [StreamEvent] {
        guard let data = sse.data.data(using: .utf8) else { return [] }
        let chunk: Chunk
        do {
            chunk = try JSONDecoder().decode(Chunk.self, from: data)
        } catch {
            // Unknown/empty chunk — ignore rather than fail the stream.
            return []
        }

        var events: [StreamEvent] = []
        let choice = chunk.choices?.first

        // First chunk → responseStarted (with the chunk id when present). Any
        // content riding on the opener falls through to the normal branches
        // below, so it's emitted as a delta too instead of only surfacing in
        // the final textCompleted.
        if !startedEmitted {
            startedEmitted = true
            responseID = chunk.id
            events.append(.responseStarted(id: chunk.id ?? UUID().uuidString))
        }

        // Tool-call fragments: accumulate per `index`. A fragment that first
        // identifies a call emits `started` *and* its same-chunk arguments
        // slice (as a delta) — dropping that slice used to truncate the args
        // of every call after the first in a parallel batch.
        if let tcs = choice?.delta?.tool_calls, !tcs.isEmpty {
            for tc in tcs {
                let idx = tc.index ?? 0
                let isNew = toolCalls[idx] == nil
                var accum = toolCalls[idx] ?? ToolCallAccum(id: "", name: "", args: "")
                if let id = tc.id { accum.id = id }
                if let name = tc.function?.name { accum.name = name }
                let fragment = tc.function?.arguments ?? ""
                accum.args += fragment
                toolCalls[idx] = accum
                if isNew { toolCallOrder.append(idx) }
                if isNew && !accum.id.isEmpty {
                    events.append(.toolCallStarted(itemID: "\(idx)", callID: accum.id, name: accum.name))
                    if !fragment.isEmpty {
                        events.append(.toolCallArgumentsDelta(itemID: "\(idx)", callID: accum.id, delta: fragment))
                    }
                } else {
                    events.append(.toolCallArgumentsDelta(itemID: "\(idx)", callID: accum.id, delta: fragment))
                }
            }
        }

        // Reasoning content (reasoning models on Chat Completions). Servers vary:
        // OpenAI/DeepSeek use `reasoning_content`; vLLM/stepfun stream it as
        // `reasoning`. Accept either.
        if let rc = (choice?.delta?.reasoning_content ?? choice?.delta?.reasoning), !rc.isEmpty {
            events.append(.reasoningSummaryDelta(itemID: itemID, delta: rc))
        }

        // Normal text content.
        if let content = choice?.delta?.content, !content.isEmpty {
            accumulatedText += content
            events.append(.textDelta(itemID: itemID, delta: content))
        }

        // Finish marker → complete whatever was being produced. Text first
        // (mirrors the wire order: content precedes the tool-call handoff),
        // then *every* accumulated tool call — `finish_reason:"tool_calls"`
        // covers the whole parallel batch, not just the first call.
        if let reason = choice?.finish_reason {
            if !accumulatedText.isEmpty {
                events.append(.textCompleted(itemID: itemID, fullText: accumulatedText))
                accumulatedText = ""
            }
            if reason == "tool_calls" {
                for idx in toolCallOrder {
                    guard let accum = toolCalls[idx] else { continue }
                    events.append(.toolCallCompleted(
                        itemID: "\(idx)", callID: accum.id, name: accum.name,
                        arguments: accum.args.isEmpty ? "{}" : accum.args
                    ))
                }
                toolCallOrder.removeAll()
                toolCalls.removeAll()
            }
        }

        // Trailing usage-only chunk (choices empty, usage present).
        if let u = chunk.usage {
            events.append(.usage(u.toUsageInfo()))
        }

        // Top-level error object.
        if let err = chunk.error {
            events.append(.responseError(message: err.message, code: err.code))
        }

        return events
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
        let prompt_tokens_details: PromptDetails?
        let completion_tokens_details: CompletionDetails?
        struct PromptDetails: Decodable { let cached_tokens: Int? }
        struct CompletionDetails: Decodable { let reasoning_tokens: Int? }

        func toUsageInfo() -> UsageInfo {
            UsageInfo(
                inputTokens: prompt_tokens ?? 0,
                outputTokens: completion_tokens ?? 0,
                reasoningTokens: completion_tokens_details?.reasoning_tokens,
                cachedInputTokens: prompt_tokens_details?.cached_tokens
            )
        }
    }

    private struct ErrorObj: Decodable {
        let message: String
        let code: String?
    }
}

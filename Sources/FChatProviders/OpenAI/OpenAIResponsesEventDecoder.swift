// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// Decodes raw SSE events from the OpenAI Responses API into `StreamEvent`.
/// Tolerant of unknown event types (they are dropped silently).
///
/// vLLM and a few other servers emit `function_call_arguments.delta`/`.done`
/// events that carry only `item_id`, not `call_id`. We keep a per-stream
/// `item_id → call_id` map populated from `output_item.added` so downstream
/// tool-call deltas can be re-projected to the canonical `call_id` the rest
/// of the runtime keys by.
public final class OpenAIResponsesEventDecoder {
    private var callIDByItemID: [String: String] = [:]
    private var nameByItemID: [String: String] = [:]
    public init() {}

    public func decode(_ sse: SSEEvent) throws -> StreamEvent? {
        let typeName = sse.event ?? extractType(from: sse.data) ?? ""
        guard let data = sse.data.data(using: .utf8) else { return nil }

        switch typeName {
        case "response.created":
            let payload = try JSONDecoder().decode(ResponseCreatedPayload.self, from: data)
            return .responseStarted(id: payload.response.id)

        case "response.output_text.delta":
            let payload = try JSONDecoder().decode(OutputTextDeltaPayload.self, from: data)
            return .textDelta(itemID: payload.item_id, delta: payload.delta)

        case "response.output_text.done":
            let payload = try JSONDecoder().decode(OutputTextDonePayload.self, from: data)
            return .textCompleted(itemID: payload.item_id, fullText: payload.text)

        case "response.reasoning_summary_text.delta",
             "response.reasoning_summary.delta",
             // vLLM / MiniMax stream the full chain-of-thought as
             // `reasoning_text.delta` rather than a separate summary. Same
             // payload shape; surface it as a reasoning delta so the UI
             // ReasoningBlock renders it live.
             "response.reasoning_text.delta":
            let payload = try JSONDecoder().decode(ReasoningSummaryDeltaPayload.self, from: data)
            return .reasoningSummaryDelta(itemID: payload.item_id, delta: payload.delta)

        case "response.reasoning.encrypted_content":
            let payload = try JSONDecoder().decode(ReasoningEncryptedPayload.self, from: data)
            return .reasoningEncryptedContent(itemID: payload.item_id, encrypted: payload.encrypted_content)

        case "response.output_item.added":
            let payload = try JSONDecoder().decode(OutputItemAddedPayload.self, from: data)
            if payload.item.type == "function_call",
               let name = payload.item.name,
               let callID = payload.item.call_id {
                let itemID = payload.item.id ?? UUID().uuidString
                callIDByItemID[itemID] = callID
                nameByItemID[itemID] = name
                return .toolCallStarted(itemID: itemID, callID: callID, name: name)
            }
            return nil

        case "response.function_call_arguments.delta":
            let payload = try JSONDecoder().decode(FunctionCallArgsDeltaPayload.self, from: data)
            let resolvedCallID = payload.call_id
                ?? callIDByItemID[payload.item_id]
                ?? payload.item_id
            return .toolCallArgumentsDelta(itemID: payload.item_id, callID: resolvedCallID, delta: payload.delta)

        case "response.function_call_arguments.done":
            let payload = try JSONDecoder().decode(FunctionCallArgsDonePayload.self, from: data)
            let resolvedCallID = payload.call_id
                ?? callIDByItemID[payload.item_id]
                ?? payload.item_id
            let resolvedName = payload.name
                ?? nameByItemID[payload.item_id]
                ?? ""
            return .toolCallCompleted(
                itemID: payload.item_id,
                callID: resolvedCallID,
                name: resolvedName,
                arguments: payload.arguments
            )

        case "response.completed":
            let payload = try JSONDecoder().decode(ResponseCompletedPayload.self, from: data)
            return .usage(payload.response.usage?.toUsageInfo() ?? UsageInfo(inputTokens: 0, outputTokens: 0))

        case "response.failed", "response.error":
            let payload = try JSONDecoder().decode(ResponseErrorPayload.self, from: data)
            return .responseError(message: payload.error.message, code: payload.error.code)

        default:
            return nil
        }
    }

    /// Some servers omit the SSE `event:` field and only emit `data: { "type": "..." }`.
    /// We pre-peek the type when that happens.
    private func extractType(from json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(TypeOnly.self, from: data))?.type
    }

    private struct TypeOnly: Decodable { let type: String? }

    // MARK: - Payloads

    private struct ResponseCreatedPayload: Decodable {
        struct R: Decodable { let id: String }
        let response: R
    }

    private struct OutputTextDeltaPayload: Decodable {
        let item_id: String
        let delta: String
    }

    private struct OutputTextDonePayload: Decodable {
        let item_id: String
        let text: String
    }

    private struct ReasoningSummaryDeltaPayload: Decodable {
        let item_id: String
        let delta: String
    }

    private struct ReasoningEncryptedPayload: Decodable {
        let item_id: String
        let encrypted_content: String
    }

    private struct OutputItemAddedPayload: Decodable {
        struct Item: Decodable {
            let id: String?
            let type: String
            let name: String?
            let call_id: String?
        }
        let item: Item
    }

    private struct FunctionCallArgsDeltaPayload: Decodable {
        let item_id: String
        let call_id: String?
        let delta: String
    }

    private struct FunctionCallArgsDonePayload: Decodable {
        let item_id: String
        let call_id: String?
        let name: String?
        let arguments: String
    }

    private struct ResponseCompletedPayload: Decodable {
        struct R: Decodable {
            struct U: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let reasoning_tokens: Int?
                let input_tokens_details: Details?
                struct Details: Decodable { let cached_tokens: Int? }

                func toUsageInfo() -> UsageInfo {
                    UsageInfo(
                        inputTokens: input_tokens ?? 0,
                        outputTokens: output_tokens ?? 0,
                        reasoningTokens: reasoning_tokens,
                        cachedInputTokens: input_tokens_details?.cached_tokens
                    )
                }
            }
            let usage: U?
        }
        let response: R
    }

    private struct ResponseErrorPayload: Decodable {
        struct E: Decodable {
            let message: String
            let code: String?
        }
        let error: E
    }
}

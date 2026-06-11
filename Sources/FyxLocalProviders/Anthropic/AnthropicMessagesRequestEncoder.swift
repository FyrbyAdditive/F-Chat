// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// Encodes a wire-neutral `ChatRequest` into an Anthropic Messages API
/// (`POST /v1/messages`) JSON body.
///
/// The main structural differences from the OpenAI Responses shape:
///  - There is no `system` *role*; the system prompt is a top-level `system`
///    string.
///  - `messages` is an alternating sequence of `{role, content:[block,…]}`.
///    Tool calls and tool results are content *blocks* (`tool_use` /
///    `tool_result`), not separate top-level items, so a `functionCall` is
///    folded into the preceding assistant message and a `functionCallOutput`
///    into a following user message. We coalesce consecutive same-role items
///    into a single message with a multi-block content array.
///  - `max_tokens` is **required** by Anthropic; we fall back to a default
///    when the request doesn't specify one.
public struct AnthropicMessagesRequestEncoder {
    /// Fallback for `max_tokens` when the request leaves it unset (Anthropic
    /// requires the field). Conservative; the model/provider can cap lower.
    public static let defaultMaxTokens = 4096

    public init() {}

    /// Anthropic's floor for `thinking.budget_tokens`.
    static let minThinkingBudget = 1_024
    /// Headroom reserved for the visible reply when we have to grow
    /// `max_tokens` to make room for a thinking budget.
    static let thinkingReplyHeadroom = 4_096

    public func encode(_ request: ChatRequest, stream: Bool) throws -> Data {
        // Resolve the thinking budget and max_tokens together — Anthropic
        // requires budget_tokens < max_tokens (it does NOT clamp; it 400s):
        //  - user left max unset → grow max_tokens to budget + headroom so a
        //    high effort doesn't 400 against the 4096 default;
        //  - user set max → clamp the budget under it, and drop thinking
        //    entirely if the clamped budget falls below Anthropic's 1024 floor.
        let requestedMax = request.maxOutputTokens ?? Self.defaultMaxTokens
        var maxTokens = requestedMax
        var thinkingBudget: Int?
        if let effort = request.reasoningEffort {
            let budget = Self.thinkingBudget(for: effort)
            if request.maxOutputTokens == nil {
                maxTokens = max(requestedMax, budget + Self.thinkingReplyHeadroom)
                thinkingBudget = budget
            } else {
                let clamped = min(budget, requestedMax - Self.minThinkingBudget)
                thinkingBudget = clamped >= Self.minThinkingBudget ? clamped : nil
            }
        }

        var json: [String: Any] = [
            "model": request.model,
            "messages": try encodeMessages(request.input),
            "stream": stream,
            "max_tokens": maxTokens,
        ]

        if let instructions = request.instructions, !instructions.isEmpty {
            json["system"] = instructions
        }
        if let budget = thinkingBudget {
            json["thinking"] = [
                "type": "enabled",
                "budget_tokens": budget,
            ]
        } else {
            // temperature/top_p are rejected alongside thinking (the API
            // requires temperature == 1 when extended thinking is on), so
            // they're only sent on non-thinking requests.
            if let temperature = request.temperature {
                json["temperature"] = temperature
            }
            if let topP = request.topP {
                json["top_p"] = topP
            }
        }
        if !request.tools.isEmpty {
            json["tools"] = try encodeTools(request.tools)
            json["tool_choice"] = encodeToolChoice(request.toolChoice, parallel: request.parallelToolCalls)
        }

        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    static func thinkingBudget(for effort: ReasoningEffort) -> Int {
        switch effort {
        case .minimal: return 1_024
        case .low: return 4_096
        case .medium: return 8_192
        case .high: return 16_384
        }
    }

    // MARK: - Messages

    /// Convert the flat `[InputItem]` into Anthropic's role-grouped messages.
    /// Tool calls/results become content blocks attached to the adjacent
    /// assistant/user message; consecutive same-role items merge into one
    /// message with a multi-block content array.
    func encodeMessages(_ items: [InputItem]) throws -> [[String: Any]] {
        var messages: [[String: Any]] = []

        func appendBlock(role: String, _ block: [String: Any]) {
            if var last = messages.last, (last["role"] as? String) == role,
               var content = last["content"] as? [[String: Any]] {
                content.append(block)
                last["content"] = content
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": role, "content": [block]])
            }
        }

        for item in items {
            switch item {
            case .message(let role, let content):
                // Anthropic has only user/assistant roles in `messages`; a
                // stray system/tool role is coerced to user (system is handled
                // top-level; tool results arrive as .functionCallOutput).
                let anthropicRole = (role == .assistant) ? "assistant" : "user"
                for c in content {
                    appendBlock(role: anthropicRole, encodeContentBlock(c))
                }
            case .functionCall(let callID, let name, let argumentsJSON):
                let input = Self.jsonObject(from: argumentsJSON)
                appendBlock(role: "assistant", [
                    "type": "tool_use",
                    "id": callID,
                    "name": name,
                    "input": input,
                ])
            case .functionCallOutput(let callID, let outputJSON):
                appendBlock(role: "user", [
                    "type": "tool_result",
                    "tool_use_id": callID,
                    "content": outputJSON,
                ])
            case .reasoning:
                // Encrypted-reasoning passthrough is an OpenAI concept; drop it.
                continue
            }
        }
        return messages
    }

    private func encodeContentBlock(_ content: InputContent) -> [String: Any] {
        switch content {
        case .inputText(let text), .outputText(let text):
            return ["type": "text", "text": text]
        case .inputImage(let url):
            return [
                "type": "image",
                "source": ["type": "url", "url": url],
            ]
        case .inputImageData(let base64, let mimeType):
            return [
                "type": "image",
                "source": ["type": "base64", "media_type": mimeType, "data": base64],
            ]
        case .thinking(let text, let signature):
            // Signed extended-thinking replay. Must lead the assistant turn
            // that issued a tool_use, which falls out of input ordering (the
            // thinking item precedes the functionCall) + same-role coalescing.
            return ["type": "thinking", "thinking": text, "signature": signature]
        case .redactedThinking(let data):
            return ["type": "redacted_thinking", "data": data]
        }
    }

    // MARK: - Tools

    private func encodeTools(_ tools: [ToolDefinition]) throws -> [[String: Any]] {
        try tools.map { tool in
            guard let schema = try JSONSerialization.jsonObject(
                with: tool.parametersSchema.raw.data(using: .utf8) ?? Data()
            ) as? [String: Any] else {
                throw ProviderError.malformedResponse("invalid tool input_schema for \(tool.name)")
            }
            return [
                "name": tool.name,
                "description": tool.description,
                "input_schema": schema,
            ]
        }
    }

    private func encodeToolChoice(_ choice: ToolChoice, parallel: Bool) -> [String: Any] {
        // Anthropic expresses "don't run tools in parallel" via
        // disable_parallel_tool_use on the tool_choice object.
        let disableParallel = !parallel
        switch choice {
        case .auto:
            return ["type": "auto", "disable_parallel_tool_use": disableParallel]
        case .none:
            // Anthropic's explicit "none": tools stay declared (prior tool_use
            // blocks in history remain valid) but the model must not call any.
            // The none variant takes no disable_parallel_tool_use field.
            return ["type": "none"]
        case .required:
            return ["type": "any", "disable_parallel_tool_use": disableParallel]
        case .named(let name):
            return ["type": "tool", "name": name, "disable_parallel_tool_use": disableParallel]
        }
    }

    // MARK: - Helpers

    /// Parse a tool-call arguments JSON string into an object for the
    /// `tool_use.input` field. Anthropic requires an object; fall back to an
    /// empty object on blank/invalid input.
    static func jsonObject(from argumentsJSON: String) -> [String: Any] {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}

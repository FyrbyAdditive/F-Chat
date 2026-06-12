// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// Encodes a wire-neutral `ChatRequest` into an Ollama native chat
/// (`POST /api/chat`) JSON body.
///
/// Shape notes vs the OpenAI/Anthropic encoders:
///  - `messages` accept system/user/assistant/tool roles directly; the system
///    prompt is a leading `{"role":"system"}` message.
///  - Images ride as a per-message `images: [base64]` array, not content parts.
///  - Sampling lives in a nested `options` object (`num_predict`, `num_ctx`,
///    `stop`, `seed`, penalties) rather than top-level fields.
///  - Tool calls are assistant-message `tool_calls` whose `arguments` is a
///    JSON *object*; tool results are `{"role":"tool","content":…,"tool_name":…}`
///    — Ollama keys results by tool name, not call id.
///  - `think: true` enables thinking models' reasoning stream. Ollama's toggle
///    is boolean, so any configured effort level maps to `true`.
public struct OllamaChatRequestEncoder {
    public init() {}

    public func encode(_ request: ChatRequest, stream: Bool) throws -> Data {
        var messages: [[String: Any]] = []
        if let instructions = request.instructions, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        messages.append(contentsOf: encodeMessages(request.input))

        var json: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": stream,
        ]

        var options: [String: Any] = [:]
        if let temperature = request.temperature { options["temperature"] = temperature }
        if let topP = request.topP { options["top_p"] = topP }
        if let maxOut = request.maxOutputTokens { options["num_predict"] = maxOut }
        if let stops = request.stopSequences, !stops.isEmpty { options["stop"] = stops }
        if let seed = request.seed { options["seed"] = seed }
        if let fp = request.frequencyPenalty { options["frequency_penalty"] = fp }
        if let pp = request.presencePenalty { options["presence_penalty"] = pp }
        // Match the server-side window to what the app budgeted. Without
        // num_ctx Ollama serves its small default context regardless of the
        // model's maximum and silently truncates the prompt.
        if let window = request.contextWindowHint { options["num_ctx"] = window }
        if !options.isEmpty { json["options"] = options }

        if request.reasoningEffort != nil {
            json["think"] = true
        }
        if !request.tools.isEmpty {
            json["tools"] = try encodeTools(request.tools)
            // Ollama has no tool_choice equivalent; the model decides.
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    // MARK: - Messages

    func encodeMessages(_ items: [InputItem]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        // callID → tool name, for resolving tool results (Ollama keys them by
        // name). Populated as functionCall items stream past in input order.
        var toolNamesByCallID: [String: String] = [:]

        for item in items {
            switch item {
            case .message(let role, let content):
                var text: [String] = []
                var images: [String] = []
                for part in content {
                    switch part {
                    case .inputText(let t), .outputText(let t):
                        text.append(t)
                    case .inputImageData(let base64, _):
                        images.append(base64)
                    case .inputImage:
                        // Ollama doesn't fetch URLs; the composer always sends
                        // image data, so URL images are dropped here.
                        break
                    case .thinking, .redactedThinking:
                        // Anthropic replay blocks; no Ollama representation.
                        break
                    }
                }
                var message: [String: Any] = [
                    "role": ollamaRole(role),
                    "content": text.joined(separator: "\n"),
                ]
                if !images.isEmpty { message["images"] = images }
                // A message stripped of all representable content disappears.
                if text.isEmpty && images.isEmpty { continue }
                messages.append(message)

            case .functionCall(let callID, let name, let argumentsJSON):
                toolNamesByCallID[callID] = name
                let call: [String: Any] = [
                    "function": [
                        "name": name,
                        "arguments": AnthropicMessagesRequestEncoder.jsonObject(from: argumentsJSON),
                    ],
                ]
                // Fold into a trailing assistant message when present, else
                // start one — mirrors how Ollama itself emits tool calls.
                if var last = messages.last, (last["role"] as? String) == "assistant" {
                    var calls = (last["tool_calls"] as? [[String: Any]]) ?? []
                    calls.append(call)
                    last["tool_calls"] = calls
                    messages[messages.count - 1] = last
                } else {
                    messages.append([
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [call],
                    ])
                }

            case .functionCallOutput(let callID, let outputJSON):
                var message: [String: Any] = [
                    "role": "tool",
                    "content": outputJSON,
                ]
                if let name = toolNamesByCallID[callID] {
                    message["tool_name"] = name
                }
                messages.append(message)

            case .reasoning:
                // Encrypted-reasoning passthrough is a Responses concept; drop.
                continue
            }
        }
        return messages
    }

    private func ollamaRole(_ role: MessageRole) -> String {
        switch role {
        case .assistant: return "assistant"
        case .system: return "system"
        case .tool: return "tool"
        case .user: return "user"
        }
    }

    // MARK: - Tools

    private func encodeTools(_ tools: [ToolDefinition]) throws -> [[String: Any]] {
        try tools.map { tool in
            guard let schema = try JSONSerialization.jsonObject(
                with: tool.parametersSchema.raw.data(using: .utf8) ?? Data()
            ) as? [String: Any] else {
                throw ProviderError.malformedResponse("invalid tool parameters for \(tool.name)")
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": schema,
                ],
            ]
        }
    }
}

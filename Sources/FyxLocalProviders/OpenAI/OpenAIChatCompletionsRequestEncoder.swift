// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// Encodes a wire-neutral `ChatRequest` into an OpenAI **Chat Completions**
/// (`POST /v1/chat/completions`) JSON body.
///
/// Differences from the Responses shape:
///  - `messages: [{role, content}]` where `content` is a plain string when the
///    message is text-only, or an array of typed parts (`text` / `image_url`)
///    when it carries images. This array form is what vision models on
///    OpenAI-compatible servers expect.
///  - The system prompt is a `{role:"system"}` message (not a top-level field).
///  - Tool calls live in an assistant message's `tool_calls`; tool results are
///    `{role:"tool", tool_call_id, content}` messages.
public struct OpenAIChatCompletionsRequestEncoder {
    public init() {}

    public func encode(_ request: ChatRequest, stream: Bool) throws -> Data {
        var messages: [[String: Any]] = []
        if let instructions = request.instructions, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        messages.append(contentsOf: try encodeMessages(request.input))

        var json: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": stream,
        ]
        if stream {
            // Ask for a usage block in the final chunk.
            json["stream_options"] = ["include_usage": true]
        }
        if let temperature = request.temperature { json["temperature"] = temperature }
        if let topP = request.topP { json["top_p"] = topP }
        if let maxOut = request.maxOutputTokens { json["max_tokens"] = maxOut }
        if let effort = request.reasoningEffort { json["reasoning_effort"] = effort.rawValue }
        if !request.tools.isEmpty {
            json["tools"] = try encodeTools(request.tools)
            json["tool_choice"] = encodeToolChoice(request.toolChoice)
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    // MARK: - Messages

    /// Convert the flat `[InputItem]` into Chat Completions messages. Tool calls
    /// attach to the preceding assistant message's `tool_calls`; tool results
    /// become standalone `tool` messages. Same-role plain messages are emitted
    /// individually (Chat Completions tolerates consecutive same-role messages).
    func encodeMessages(_ items: [InputItem]) throws -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for item in items {
            switch item {
            case .message(let role, let content):
                messages.append([
                    "role": chatRole(role),
                    "content": encodeContent(content),
                ])
            case .functionCall(let callID, let name, let argumentsJSON):
                let toolCall: [String: Any] = [
                    "id": callID,
                    "type": "function",
                    "function": ["name": name, "arguments": argumentsJSON],
                ]
                // Fold into the trailing assistant message if there is one;
                // otherwise start a new assistant message carrying the call.
                if var last = messages.last, (last["role"] as? String) == "assistant",
                   last["tool_calls"] != nil || last["content"] is String {
                    var calls = (last["tool_calls"] as? [[String: Any]]) ?? []
                    calls.append(toolCall)
                    last["tool_calls"] = calls
                    messages[messages.count - 1] = last
                } else {
                    messages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [toolCall],
                    ])
                }
            case .functionCallOutput(let callID, let outputJSON):
                messages.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": outputJSON,
                ])
            case .reasoning:
                // Encrypted-reasoning passthrough is a Responses concept; drop it.
                continue
            }
        }
        return messages
    }

    private func chatRole(_ role: MessageRole) -> String {
        switch role {
        case .assistant: return "assistant"
        case .system: return "system"
        default: return "user"
        }
    }

    /// Content is a plain string when every part is text; otherwise an array of
    /// typed parts so images can ride alongside the text.
    private func encodeContent(_ content: [InputContent]) -> Any {
        let hasImage = content.contains {
            if case .inputImage = $0 { return true }
            if case .inputImageData = $0 { return true }
            return false
        }
        if !hasImage {
            // Join the text parts into a single string.
            let text = content.compactMap { part -> String? in
                switch part {
                case .inputText(let t), .outputText(let t): return t
                default: return nil
                }
            }.joined(separator: "\n")
            return text
        }
        return content.map { part -> [String: Any] in
            switch part {
            case .inputText(let t), .outputText(let t):
                return ["type": "text", "text": t]
            case .inputImage(let url):
                return ["type": "image_url", "image_url": ["url": url]]
            case .inputImageData(let base64, let mimeType):
                return ["type": "image_url", "image_url": ["url": "data:\(mimeType);base64,\(base64)"]]
            }
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
            var function: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
                "parameters": schema,
            ]
            // Structured-outputs strict mode. Only sent when enabled so older
            // OpenAI-compatible gateways that predate the field aren't tripped.
            if tool.strict { function["strict"] = true }
            return [
                "type": "function",
                "function": function,
            ]
        }
    }

    private func encodeToolChoice(_ choice: ToolChoice) -> Any {
        switch choice {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "required"
        case .named(let name):
            return ["type": "function", "function": ["name": name]]
        }
    }
}

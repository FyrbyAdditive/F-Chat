// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

public struct OpenAIResponsesRequestEncoder {
    public init() {}

    public func encode(_ request: ChatRequest, stream: Bool) throws -> Data {
        var json: [String: Any] = [
            "model": request.model,
            "input": encodeInput(request.input),
            "stream": stream,
            "parallel_tool_calls": request.parallelToolCalls,
            "store": request.store,
        ]

        if let instructions = request.instructions, !instructions.isEmpty {
            json["instructions"] = instructions
        }
        if let prev = request.previousResponseID {
            json["previous_response_id"] = prev
        }
        if let temperature = request.temperature {
            json["temperature"] = temperature
        }
        if let topP = request.topP {
            json["top_p"] = topP
        }
        if let maxTokens = request.maxOutputTokens {
            json["max_output_tokens"] = maxTokens
        }
        if request.reasoningEffort != nil || request.reasoningSummary != nil {
            var reasoning: [String: Any] = [:]
            if let effort = request.reasoningEffort {
                reasoning["effort"] = effort.rawValue
            }
            if let summary = request.reasoningSummary {
                reasoning["summary"] = summary.rawValue
            }
            json["reasoning"] = reasoning
        }
        if !request.tools.isEmpty {
            json["tools"] = try encodeTools(request.tools)
        }
        switch request.toolChoice {
        case .auto: json["tool_choice"] = "auto"
        case .none: json["tool_choice"] = "none"
        case .required: json["tool_choice"] = "required"
        case .named(let name):
            json["tool_choice"] = ["type": "function", "name": name]
        }
        if request.includeEncryptedReasoning {
            json["include"] = ["reasoning.encrypted_content"]
        }

        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func encodeInput(_ items: [InputItem]) -> [[String: Any]] {
        items.map { item in
            switch item {
            case .message(let role, let content):
                return [
                    "type": "message",
                    "role": role.rawValue,
                    "content": content.map(encodeContent),
                ]
            case .functionCall(let callID, let name, let arguments):
                return [
                    "type": "function_call",
                    "call_id": callID,
                    "name": name,
                    "arguments": arguments,
                ]
            case .functionCallOutput(let callID, let output):
                return [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output,
                ]
            case .reasoning(let encrypted):
                return [
                    "type": "reasoning",
                    "encrypted_content": encrypted,
                ]
            }
        }
    }

    private func encodeContent(_ content: InputContent) -> [String: Any] {
        switch content {
        case .inputText(let text):
            return ["type": "input_text", "text": text]
        case .outputText(let text):
            return ["type": "output_text", "text": text]
        case .inputImage(let url):
            return ["type": "input_image", "image_url": url]
        case .inputImageData(let base64, let mimeType):
            return ["type": "input_image", "image_url": "data:\(mimeType);base64,\(base64)"]
        }
    }

    private func encodeTools(_ tools: [ToolDefinition]) throws -> [[String: Any]] {
        try tools.map { tool in
            guard let schema = try JSONSerialization.jsonObject(with: tool.parametersSchema.raw.data(using: .utf8) ?? Data()) as? [String: Any] else {
                throw ProviderError.malformedResponse("invalid tool parametersSchema for \(tool.name)")
            }
            return [
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": schema,
                "strict": tool.strict,
            ]
        }
    }
}

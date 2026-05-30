// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

public struct ChatRequest: Sendable, Hashable {
    public var model: String
    public var input: [InputItem]
    public var instructions: String?
    public var previousResponseID: String?
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int?
    public var reasoningEffort: ReasoningEffort?
    /// Asks the server to stream a summary of the model's chain-of-thought
    /// as `response.reasoning_summary_text.delta` events. Without this set,
    /// reasoning happens silently on the server and we just see a gap
    /// between `responseStarted` and the first `textDelta`.
    public var reasoningSummary: ReasoningSummary?
    public var parallelToolCalls: Bool
    public var tools: [ToolDefinition]
    public var toolChoice: ToolChoice
    public var store: Bool
    public var includeEncryptedReasoning: Bool

    public init(
        model: String,
        input: [InputItem],
        instructions: String? = nil,
        previousResponseID: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        reasoningSummary: ReasoningSummary? = nil,
        parallelToolCalls: Bool = true,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        store: Bool = true,
        includeEncryptedReasoning: Bool = false
    ) {
        self.model = model
        self.input = input
        self.instructions = instructions
        self.previousResponseID = previousResponseID
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.reasoningSummary = reasoningSummary
        self.parallelToolCalls = parallelToolCalls
        self.tools = tools
        self.toolChoice = toolChoice
        self.store = store
        self.includeEncryptedReasoning = includeEncryptedReasoning
    }
}

/// Verbosity of the reasoning summary stream. `.auto` lets the server pick.
public enum ReasoningSummary: String, Sendable, Hashable {
    case auto
    case concise
    case detailed
}

public enum InputItem: Sendable, Hashable {
    case message(role: MessageRole, content: [InputContent])
    case functionCall(callID: String, name: String, argumentsJSON: String)
    case functionCallOutput(callID: String, outputJSON: String)
    case reasoning(encryptedContent: String)
}

public enum InputContent: Sendable, Hashable {
    case inputText(String)
    case outputText(String)
    case inputImage(url: String)
    case inputImageData(base64: String, mimeType: String)
}

public enum ToolChoice: Sendable, Hashable {
    case auto
    case none
    case required
    case named(String)
}

public struct ToolDefinition: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parametersSchema: JSONSchema
    public var strict: Bool

    public init(name: String, description: String, parametersSchema: JSONSchema, strict: Bool = false) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.strict = strict
    }
}

/// Minimal JSON-schema representation: just an opaque payload we forward as-is.
public struct JSONSchema: Sendable, Hashable {
    public var raw: String

    public init(raw: String) { self.raw = raw }

    public static let emptyObject = JSONSchema(raw: #"{"type":"object","properties":{},"additionalProperties":false}"#)
}

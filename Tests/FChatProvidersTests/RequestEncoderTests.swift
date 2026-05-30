// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders
@testable import FChatCore

@Suite("OpenAIResponsesRequestEncoder")
struct OpenAIResponsesRequestEncoderTests {
    let encoder = OpenAIResponsesRequestEncoder()

    private func decode(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse("not an object")
        }
        return obj
    }

    @Test func encodesMinimalMessageRequest() throws {
        let req = ChatRequest(
            model: "gpt-4o-mini",
            input: [.message(role: .user, content: [.inputText("Hi")])]
        )
        let data = try encoder.encode(req, stream: true)
        let json = try decode(data)
        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect(json["stream"] as? Bool == true)
        #expect(json["store"] as? Bool == true)
        #expect(json["parallel_tool_calls"] as? Bool == true)
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input[0]["type"] as? String == "message")
        #expect(input[0]["role"] as? String == "user")
    }

    @Test func encodesPreviousResponseIDWhenSet() throws {
        let req = ChatRequest(
            model: "x",
            input: [.message(role: .user, content: [.inputText("hi")])],
            previousResponseID: "resp_42"
        )
        let json = try decode(try encoder.encode(req, stream: true))
        #expect(json["previous_response_id"] as? String == "resp_42")
    }

    @Test func encodesInstructionsAndSamplingKnobs() throws {
        let req = ChatRequest(
            model: "x",
            input: [.message(role: .user, content: [.inputText("hi")])],
            instructions: "Be brief.",
            temperature: 0.2,
            topP: 0.9,
            maxOutputTokens: 256,
            reasoningEffort: .high
        )
        let json = try decode(try encoder.encode(req, stream: true))
        #expect(json["instructions"] as? String == "Be brief.")
        #expect(json["temperature"] as? Double == 0.2)
        #expect(json["top_p"] as? Double == 0.9)
        #expect(json["max_output_tokens"] as? Int == 256)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "high")
    }

    @Test func encodesFunctionCallContinuation() throws {
        let req = ChatRequest(
            model: "x",
            input: [
                .functionCall(callID: "call_1", name: "web_search", argumentsJSON: #"{"q":"swift"}"#),
                .functionCallOutput(callID: "call_1", outputJSON: #"[{"title":"Swift.org"}]"#),
            ]
        )
        let json = try decode(try encoder.encode(req, stream: true))
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input[0]["type"] as? String == "function_call")
        #expect(input[0]["call_id"] as? String == "call_1")
        #expect(input[1]["type"] as? String == "function_call_output")
        #expect(input[1]["output"] as? String == #"[{"title":"Swift.org"}]"#)
    }

    @Test func encodesTools() throws {
        let tool = ToolDefinition(
            name: "web_search",
            description: "Search the web",
            parametersSchema: JSONSchema(raw: #"{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}"#)
        )
        let req = ChatRequest(
            model: "x",
            input: [.message(role: .user, content: [.inputText("hi")])],
            tools: [tool]
        )
        let json = try decode(try encoder.encode(req, stream: true))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        #expect(tools[0]["name"] as? String == "web_search")
        let params = try #require(tools[0]["parameters"] as? [String: Any])
        #expect(params["type"] as? String == "object")
    }

    @Test func encodesToolChoiceVariants() throws {
        var req = ChatRequest(model: "x", input: [.message(role: .user, content: [.inputText("hi")])], toolChoice: .none)
        var json = try decode(try encoder.encode(req, stream: true))
        #expect(json["tool_choice"] as? String == "none")

        req.toolChoice = .required
        json = try decode(try encoder.encode(req, stream: true))
        #expect(json["tool_choice"] as? String == "required")

        req.toolChoice = .named("rag_search")
        json = try decode(try encoder.encode(req, stream: true))
        let choice = try #require(json["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "function")
        #expect(choice["name"] as? String == "rag_search")
    }

    @Test func encryptedReasoningInclude() throws {
        let req = ChatRequest(
            model: "x",
            input: [.message(role: .user, content: [.inputText("hi")])],
            store: false,
            includeEncryptedReasoning: true
        )
        let json = try decode(try encoder.encode(req, stream: true))
        let include = try #require(json["include"] as? [String])
        #expect(include == ["reasoning.encrypted_content"])
    }
}

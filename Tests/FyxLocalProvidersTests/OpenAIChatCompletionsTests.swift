// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalProviders
@testable import FyxLocalCore

@Suite("OpenAIChatCompletionsRequestEncoder")
struct OpenAIChatCompletionsRequestEncoderTests {
    let encoder = OpenAIChatCompletionsRequestEncoder()

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func textOnlyMessageUsesStringContent() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [.inputText("hello")])],
            instructions: "be brief"
        )
        let json = try object(try encoder.encode(req, stream: true))
        #expect(json["model"] as? String == "m")
        #expect(json["stream"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "be brief")
        #expect(messages[1]["role"] as? String == "user")
        // Text-only → content is a plain string, not an array.
        #expect(messages[1]["content"] as? String == "hello")
    }

    @Test func imageMessageUsesContentPartsArray() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [
                .inputText("describe"),
                .inputImageData(base64: "QUJD", mimeType: "image/png"),
            ])]
        )
        let json = try object(try encoder.encode(req, stream: true))
        let messages = try #require(json["messages"] as? [[String: Any]])
        let parts = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[0]["text"] as? String == "describe")
        #expect(parts[1]["type"] as? String == "image_url")
        let imageURL = try #require(parts[1]["image_url"] as? [String: Any])
        #expect(imageURL["url"] as? String == "data:image/png;base64,QUJD")
    }

    @Test func toolsAndToolChoiceEncoded() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [.inputText("hi")])],
            tools: [ToolDefinition(name: "get_time", description: "now", parametersSchema: .emptyObject)],
            toolChoice: .required
        )
        let json = try object(try encoder.encode(req, stream: true))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "function")
        let fn = try #require(tools[0]["function"] as? [String: Any])
        #expect(fn["name"] as? String == "get_time")
        #expect(fn["parameters"] is [String: Any])
        #expect(json["tool_choice"] as? String == "required")
    }

    @Test func toolCallAndResultRoundTrip() throws {
        let req = ChatRequest(
            model: "m",
            input: [
                .message(role: .user, content: [.inputText("time?")]),
                .functionCall(callID: "call_1", name: "get_time", argumentsJSON: "{}"),
                .functionCallOutput(callID: "call_1", outputJSON: "{\"t\":\"now\"}"),
            ]
        )
        let json = try object(try encoder.encode(req, stream: true))
        let messages = try #require(json["messages"] as? [[String: Any]])
        // assistant message carries tool_calls, tool message carries the result.
        let assistant = try #require(messages.first { ($0["role"] as? String) == "assistant" })
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect((calls[0]["function"] as? [String: Any])?["name"] as? String == "get_time")
        let tool = try #require(messages.first { ($0["role"] as? String) == "tool" })
        #expect(tool["tool_call_id"] as? String == "call_1")
    }

    @Test func samplingParams() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [.inputText("hi")])],
            temperature: 0.5, topP: 0.9, maxOutputTokens: 256
        )
        let json = try object(try encoder.encode(req, stream: true))
        #expect(json["temperature"] as? Double == 0.5)
        #expect(json["top_p"] as? Double == 0.9)
        #expect(json["max_tokens"] as? Int == 256)
        #expect((json["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }
}

@Suite("OpenAIChatCompletionsEventDecoder")
struct OpenAIChatCompletionsEventDecoderTests {
    private func sse(_ data: String) -> SSEEvent { SSEEvent(event: nil, data: data) }

    @Test func firstChunkStartsThenContentDeltas() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        let started = try d.decode(sse(#"{"id":"chatcmpl_1","choices":[{"delta":{"role":"assistant"}}]}"#))
        guard case .responseStarted(let id) = started else { Issue.record("expected started"); return }
        #expect(id == "chatcmpl_1")

        let delta = try d.decode(sse(#"{"id":"chatcmpl_1","choices":[{"delta":{"content":"Hel"}}]}"#))
        guard case .textDelta(_, let t) = delta else { Issue.record("expected textDelta"); return }
        #expect(t == "Hel")
    }

    @Test func finishEmitsTextCompletedIncludingFirstChunkContent() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        // First chunk doubles as responseStarted but its content is still
        // accumulated, so nothing is lost.
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"Hel"}}]}"#))
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"lo"}}]}"#))
        let done = try d.decode(sse(#"{"id":"c","choices":[{"delta":{},"finish_reason":"stop"}]}"#))
        guard case .textCompleted(_, let full) = done else { Issue.record("expected textCompleted, got \(String(describing: done))"); return }
        #expect(full == "Hello")
    }

    @Test func contentAccumulatesAfterStart() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))  // responseStarted
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"Hel"}}]}"#))
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"lo"}}]}"#))
        let done = try d.decode(sse(#"{"id":"c","choices":[{"finish_reason":"stop"}]}"#))
        guard case .textCompleted(_, let full) = done else { Issue.record("expected textCompleted"); return }
        #expect(full == "Hello")
    }

    @Test func reasoningContentDelta() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))
        let r = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"reasoning_content":"think"}}]}"#))
        guard case .reasoningSummaryDelta(_, let t) = r else { Issue.record("expected reasoning"); return }
        #expect(t == "think")
    }

    @Test func reasoningKeyVariantDelta() throws {
        // vLLM/stepfun stream reasoning under `reasoning` (not `reasoning_content`),
        // with content explicitly null on those chunks.
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant","content":""}}]}"#))
        let r = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":null,"reasoning":"The user"}}]}"#))
        guard case .reasoningSummaryDelta(_, let t) = r else { Issue.record("expected reasoning, got \(String(describing: r))"); return }
        #expect(t == "The user")
    }

    @Test func toolCallStreamedThenCompleted() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))
        let started = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_time","arguments":""}}]}}]}"#))
        guard case .toolCallStarted(_, let cid, let name) = started else { Issue.record("expected toolCallStarted"); return }
        #expect(cid == "call_1"); #expect(name == "get_time")

        let argsDelta = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"x\":1}"}}]}}]}"#))
        guard case .toolCallArgumentsDelta(_, _, let dArgs) = argsDelta else { Issue.record("expected argsDelta"); return }
        #expect(dArgs == "{\"x\":1}")

        let done = try d.decode(sse(#"{"id":"c","choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#))
        guard case .toolCallCompleted(_, let cid2, let name2, let args) = done else { Issue.record("expected toolCallCompleted"); return }
        #expect(cid2 == "call_1"); #expect(name2 == "get_time"); #expect(args == "{\"x\":1}")
    }

    @Test func usageChunk() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))
        let u = try d.decode(sse(#"{"id":"c","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":7}}"#))
        guard case .usage(let info) = u else { Issue.record("expected usage, got \(String(describing: u))"); return }
        #expect(info.inputTokens == 12)
        #expect(info.outputTokens == 7)
    }
}

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
        // Non-strict tools omit the field entirely (older gateways).
        #expect(fn["strict"] == nil)
        #expect(json["tool_choice"] as? String == "required")
    }

    @Test func strictToolEncodesStrictFlag() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [.inputText("hi")])],
            tools: [ToolDefinition(name: "lookup", description: "d", parametersSchema: .emptyObject, strict: true)]
        )
        let json = try object(try encoder.encode(req, stream: true))
        let fn = try #require((json["tools"] as? [[String: Any]])?.first?["function"] as? [String: Any])
        #expect(fn["strict"] as? Bool == true)
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

    @Test func thinkingContentIsDroppedAndEmptyMessagesSkipped() throws {
        // Anthropic thinking blocks have no CC representation; a message left
        // with nothing after dropping them must not appear at all.
        let req = ChatRequest(
            model: "m",
            input: [
                .message(role: .user, content: [.inputText("hi")]),
                .message(role: .assistant, content: [.thinking(text: "secret", signature: "sig")]),
                .message(role: .assistant, content: [.redactedThinking(data: "X"), .outputText("visible")]),
            ]
        )
        let json = try object(try encoder.encode(req, stream: true))
        let messages = try #require(json["messages"] as? [[String: Any]])
        // user + the assistant message that still has text; thinking-only one gone.
        #expect(messages.count == 2)
        #expect(messages[1]["content"] as? String == "visible")
        #expect(!String(data: try encoder.encode(req, stream: true), encoding: .utf8)!.contains("secret"))
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
        // Unset extras stay off the wire entirely.
        #expect(json["stop"] == nil)
        #expect(json["frequency_penalty"] == nil)
        #expect(json["presence_penalty"] == nil)
        #expect(json["seed"] == nil)
    }

    @Test func extendedSamplingParamsEncoded() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [.inputText("hi")])],
            stopSequences: ["END", "STOP"],
            frequencyPenalty: 0.5,
            presencePenalty: -0.25,
            seed: 1234
        )
        let json = try object(try encoder.encode(req, stream: true))
        #expect(json["stop"] as? [String] == ["END", "STOP"])
        #expect(json["frequency_penalty"] as? Double == 0.5)
        #expect(json["presence_penalty"] as? Double == -0.25)
        #expect(json["seed"] as? Int == 1234)
    }
}

@Suite("OpenAIChatCompletionsEventDecoder")
struct OpenAIChatCompletionsEventDecoderTests {
    private func sse(_ data: String) -> SSEEvent { SSEEvent(event: nil, data: data) }

    @Test func firstChunkStartsThenContentDeltas() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        let started = try d.decode(sse(#"{"id":"chatcmpl_1","choices":[{"delta":{"role":"assistant"}}]}"#))
        guard case .responseStarted(let id) = started.first else { Issue.record("expected started"); return }
        #expect(id == "chatcmpl_1")
        #expect(started.count == 1)

        let delta = try d.decode(sse(#"{"id":"chatcmpl_1","choices":[{"delta":{"content":"Hel"}}]}"#))
        guard case .textDelta(_, let t) = delta.first else { Issue.record("expected textDelta"); return }
        #expect(t == "Hel")
    }

    @Test func openerContentEmitsStartedAndDelta() throws {
        // A first chunk that carries content yields responseStarted *and* the
        // text delta (the old contract accumulated it silently).
        let d = OpenAIChatCompletionsEventDecoder()
        let events = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"Hel"}}]}"#))
        guard case .responseStarted = events.first else { Issue.record("expected started first"); return }
        guard events.count == 2, case .textDelta(_, let t) = events[1] else {
            Issue.record("expected textDelta second, got \(events)"); return
        }
        #expect(t == "Hel")
    }

    @Test func finishEmitsTextCompletedIncludingFirstChunkContent() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        // First chunk doubles as responseStarted but its content is still
        // accumulated, so nothing is lost.
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"Hel"}}]}"#))
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"lo"}}]}"#))
        let done = try d.decode(sse(#"{"id":"c","choices":[{"delta":{},"finish_reason":"stop"}]}"#))
        guard case .textCompleted(_, let full) = done.first else { Issue.record("expected textCompleted, got \(done)"); return }
        #expect(full == "Hello")
    }

    @Test func contentAccumulatesAfterStart() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))  // responseStarted
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"Hel"}}]}"#))
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"lo"}}]}"#))
        let done = try d.decode(sse(#"{"id":"c","choices":[{"finish_reason":"stop"}]}"#))
        guard case .textCompleted(_, let full) = done.first else { Issue.record("expected textCompleted"); return }
        #expect(full == "Hello")
    }

    @Test func reasoningContentDelta() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))
        let r = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"reasoning_content":"think"}}]}"#))
        guard case .reasoningSummaryDelta(_, let t) = r.first else { Issue.record("expected reasoning"); return }
        #expect(t == "think")
    }

    @Test func reasoningKeyVariantDelta() throws {
        // vLLM/stepfun stream reasoning under `reasoning` (not `reasoning_content`),
        // with content explicitly null on those chunks.
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant","content":""}}]}"#))
        let r = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":null,"reasoning":"The user"}}]}"#))
        guard case .reasoningSummaryDelta(_, let t) = r.first else { Issue.record("expected reasoning, got \(r)"); return }
        #expect(t == "The user")
    }

    @Test func toolCallStreamedThenCompleted() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))
        let started = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_time","arguments":""}}]}}]}"#))
        guard case .toolCallStarted(_, let cid, let name) = started.first else { Issue.record("expected toolCallStarted"); return }
        #expect(cid == "call_1"); #expect(name == "get_time")
        // Empty arguments fragment on the started chunk → no trailing delta event.
        #expect(started.count == 1)

        let argsDelta = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"x\":1}"}}]}}]}"#))
        guard case .toolCallArgumentsDelta(_, _, let dArgs) = argsDelta.first else { Issue.record("expected argsDelta"); return }
        #expect(dArgs == "{\"x\":1}")

        let done = try d.decode(sse(#"{"id":"c","choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#))
        guard case .toolCallCompleted(_, let cid2, let name2, let args) = done.first else { Issue.record("expected toolCallCompleted"); return }
        #expect(cid2 == "call_1"); #expect(name2 == "get_time"); #expect(args == "{\"x\":1}")
    }

    @Test func parallelToolCallsAllComplete() throws {
        // Two calls streamed in parallel (interleaved fragments, distinct
        // `index`). Regression: the old one-event contract completed only the
        // first call and swallowed the second call's first args fragment.
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))

        let s0 = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_time","arguments":"{\"tz\":"}}]}}]}"#))
        guard case .toolCallStarted(_, "call_a", "get_time") = s0.first else { Issue.record("expected call_a started"); return }
        // The same-chunk fragment must surface as a delta, not vanish.
        guard s0.count == 2, case .toolCallArgumentsDelta(_, "call_a", "{\"tz\":") = s0[1] else {
            Issue.record("expected call_a same-chunk args delta, got \(s0)"); return
        }

        let s1 = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"get_weather","arguments":"{\"city\":"}}]}}]}"#))
        guard case .toolCallStarted(_, "call_b", "get_weather") = s1.first else { Issue.record("expected call_b started"); return }
        guard s1.count == 2, case .toolCallArgumentsDelta(_, "call_b", "{\"city\":") = s1[1] else {
            Issue.record("expected call_b same-chunk args delta, got \(s1)"); return
        }

        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"UTC\"}"}}]}}]}"#))
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"Oslo\"}"}}]}}]}"#))

        let done = try d.decode(sse(#"{"id":"c","choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#))
        #expect(done.count == 2)
        guard case .toolCallCompleted(_, "call_a", "get_time", let argsA) = done[0] else {
            Issue.record("expected call_a completed first, got \(done)"); return
        }
        guard case .toolCallCompleted(_, "call_b", "get_weather", let argsB) = done[1] else {
            Issue.record("expected call_b completed second, got \(done)"); return
        }
        #expect(argsA == "{\"tz\":\"UTC\"}")
        #expect(argsB == "{\"city\":\"Oslo\"}")
    }

    @Test func textAndToolCallsBothCompleteOnFinish() throws {
        // A turn that streams text *and* calls a tool: the finish marker must
        // complete the text first, then the tool call.
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"content":"Checking…"}}]}"#))
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"now","arguments":""}}]}}]}"#))
        let done = try d.decode(sse(#"{"id":"c","choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#))
        #expect(done.count == 2)
        guard case .textCompleted(_, "Checking…") = done[0] else { Issue.record("expected textCompleted first, got \(done)"); return }
        guard case .toolCallCompleted(_, "call_1", "now", "{}") = done[1] else { Issue.record("expected toolCallCompleted second, got \(done)"); return }
    }

    @Test func usageChunk() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))
        let u = try d.decode(sse(#"{"id":"c","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":7}}"#))
        guard case .usage(let info) = u.first else { Issue.record("expected usage, got \(u)"); return }
        #expect(info.inputTokens == 12)
        #expect(info.outputTokens == 7)
        #expect(info.reasoningTokens == nil)
    }

    @Test func usageChunkCarriesReasoningTokens() throws {
        let d = OpenAIChatCompletionsEventDecoder()
        _ = try d.decode(sse(#"{"id":"c","choices":[{"delta":{"role":"assistant"}}]}"#))
        let u = try d.decode(sse(#"{"id":"c","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":40,"completion_tokens_details":{"reasoning_tokens":33},"prompt_tokens_details":{"cached_tokens":8}}}"#))
        guard case .usage(let info) = u.first else { Issue.record("expected usage, got \(u)"); return }
        #expect(info.reasoningTokens == 33)
        #expect(info.cachedInputTokens == 8)
    }
}

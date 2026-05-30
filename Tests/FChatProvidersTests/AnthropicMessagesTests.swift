// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders
@testable import FChatCore

@Suite("AnthropicMessagesEventDecoder")
struct AnthropicMessagesEventDecoderTests {
    private func decoder() -> AnthropicMessagesEventDecoder { AnthropicMessagesEventDecoder() }

    @Test func messageStartGivesResponseStarted() throws {
        let d = decoder()
        let sse = SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{"id":"msg_01","usage":{"input_tokens":12}}}"#)
        guard case .responseStarted(let id) = try d.decode(sse) else { Issue.record("expected .responseStarted"); return }
        #expect(id == "msg_01")
    }

    @Test func textStreamFlow() throws {
        let d = decoder()
        _ = try d.decode(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":5}}}"#))
        _ = try d.decode(SSEEvent(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#))

        let d1 = try d.decode(SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#))
        guard case .textDelta(let item1, let delta1) = d1 else { Issue.record("expected .textDelta"); return }
        #expect(item1 == "msg_1:0")
        #expect(delta1 == "Hel")

        _ = try d.decode(SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#))

        let stop = try d.decode(SSEEvent(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#))
        guard case .textCompleted(let item2, let full) = stop else { Issue.record("expected .textCompleted"); return }
        #expect(item2 == "msg_1:0")
        #expect(full == "Hello")
    }

    @Test func toolUseFlowAccumulatesArgs() throws {
        let d = decoder()
        _ = try d.decode(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":1}}}"#))
        let start = try d.decode(SSEEvent(event: "content_block_start", data: #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_9","name":"web_search"}}"#))
        guard case .toolCallStarted(let itemID, let callID, let name) = start else { Issue.record("expected .toolCallStarted"); return }
        #expect(callID == "toolu_9")
        #expect(name == "web_search")
        #expect(itemID == "m:1")

        let dlt = try d.decode(SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}"#))
        guard case .toolCallArgumentsDelta(_, let dcall, let dchunk) = dlt else { Issue.record("expected .toolCallArgumentsDelta"); return }
        #expect(dcall == "toolu_9")
        #expect(dchunk == "{\"q\":")
        _ = try d.decode(SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"cats\"}"}}"#))

        let stop = try d.decode(SSEEvent(event: "content_block_stop", data: #"{"type":"content_block_stop","index":1}"#))
        guard case .toolCallCompleted(_, let ccall, let cname, let args) = stop else { Issue.record("expected .toolCallCompleted"); return }
        #expect(ccall == "toolu_9")
        #expect(cname == "web_search")
        #expect(args == "{\"q\":\"cats\"}")
    }

    @Test func emptyToolInputNormalisesToObject() throws {
        let d = decoder()
        _ = try d.decode(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{"id":"m"}}"#))
        _ = try d.decode(SSEEvent(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t0","name":"now"}}"#))
        let stop = try d.decode(SSEEvent(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#))
        guard case .toolCallCompleted(_, _, _, let args) = stop else { Issue.record("expected completed"); return }
        #expect(args == "{}")
    }

    @Test func thinkingDeltaMapsToReasoning() throws {
        let d = decoder()
        _ = try d.decode(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{"id":"m"}}"#))
        _ = try d.decode(SSEEvent(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#))
        let ev = try d.decode(SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#))
        guard case .reasoningSummaryDelta(_, let delta) = ev else { Issue.record("expected .reasoningSummaryDelta"); return }
        #expect(delta == "hmm")
    }

    @Test func messageDeltaGivesUsageAndStopCompletes() throws {
        let d = decoder()
        _ = try d.decode(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":7}}}"#))
        let usage = try d.decode(SSEEvent(event: "message_delta", data: #"{"type":"message_delta","usage":{"output_tokens":42}}"#))
        guard case .usage(let info) = usage else { Issue.record("expected .usage"); return }
        #expect(info.inputTokens == 7)
        #expect(info.outputTokens == 42)
        guard case .completed = try d.decode(SSEEvent(event: "message_stop", data: #"{"type":"message_stop"}"#)) else {
            Issue.record("expected .completed"); return
        }
    }

    @Test func errorEvent() throws {
        let d = decoder()
        let ev = try d.decode(SSEEvent(event: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        guard case .responseError(let msg, let code) = ev else { Issue.record("expected .responseError"); return }
        #expect(msg == "Overloaded")
        #expect(code == "overloaded_error")
    }

    @Test func pingAndUnknownAreDropped() throws {
        let d = decoder()
        #expect(try d.decode(SSEEvent(event: "ping", data: #"{"type":"ping"}"#)) == nil)
        #expect(try d.decode(SSEEvent(event: "wat", data: #"{"type":"wat"}"#)) == nil)
    }
}

@Suite("AnthropicMessagesRequestEncoder")
struct AnthropicMessagesRequestEncoderTests {
    private func encodeToObject(_ request: ChatRequest) throws -> [String: Any] {
        let data = try AnthropicMessagesRequestEncoder().encode(request, stream: true)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func systemAndBasicMessage() throws {
        let req = ChatRequest(
            model: "claude-sonnet-4",
            input: [.message(role: .user, content: [.inputText("hi")])],
            instructions: "Be terse.",
            maxOutputTokens: 1000
        )
        let obj = try encodeToObject(req)
        #expect(obj["model"] as? String == "claude-sonnet-4")
        #expect(obj["system"] as? String == "Be terse.")
        #expect(obj["max_tokens"] as? Int == 1000)
        #expect(obj["stream"] as? Bool == true)
        let messages = try #require(obj["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "hi")
    }

    @Test func defaultsMaxTokensWhenUnset() throws {
        let req = ChatRequest(model: "claude", input: [.message(role: .user, content: [.inputText("x")])])
        let obj = try encodeToObject(req)
        #expect(obj["max_tokens"] as? Int == AnthropicMessagesRequestEncoder.defaultMaxTokens)
    }

    @Test func toolCallAndResultBecomeBlocks() throws {
        let req = ChatRequest(
            model: "claude",
            input: [
                .message(role: .user, content: [.inputText("search cats")]),
                .functionCall(callID: "toolu_1", name: "web_search", argumentsJSON: #"{"q":"cats"}"#),
                .functionCallOutput(callID: "toolu_1", outputJSON: #"{"results":[]}"#),
            ],
            maxOutputTokens: 500
        )
        let obj = try encodeToObject(req)
        let messages = try #require(obj["messages"] as? [[String: Any]])
        // user(text) | assistant(tool_use) | user(tool_result)
        #expect(messages.count == 3)
        #expect(messages[1]["role"] as? String == "assistant")
        let toolUse = try #require((messages[1]["content"] as? [[String: Any]])?.first)
        #expect(toolUse["type"] as? String == "tool_use")
        #expect(toolUse["id"] as? String == "toolu_1")
        #expect(toolUse["name"] as? String == "web_search")
        #expect((toolUse["input"] as? [String: Any])?["q"] as? String == "cats")
        #expect(messages[2]["role"] as? String == "user")
        let toolResult = try #require((messages[2]["content"] as? [[String: Any]])?.first)
        #expect(toolResult["type"] as? String == "tool_result")
        #expect(toolResult["tool_use_id"] as? String == "toolu_1")
    }

    @Test func consecutiveSameRoleCoalesce() throws {
        let req = ChatRequest(
            model: "claude",
            input: [
                .message(role: .user, content: [.inputText("a")]),
                .message(role: .user, content: [.inputText("b")]),
            ]
        )
        let obj = try encodeToObject(req)
        let messages = try #require(obj["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect((messages[0]["content"] as? [[String: Any]])?.count == 2)
    }

    @Test func toolsAndChoiceEncoded() throws {
        let schema = JSONSchema(raw: #"{"type":"object","properties":{"q":{"type":"string"}}}"#)
        let req = ChatRequest(
            model: "claude",
            input: [.message(role: .user, content: [.inputText("x")])],
            parallelToolCalls: false,
            tools: [ToolDefinition(name: "web_search", description: "Search", parametersSchema: schema)],
            toolChoice: .required
        )
        let obj = try encodeToObject(req)
        let tools = try #require(obj["tools"] as? [[String: Any]])
        #expect(tools[0]["name"] as? String == "web_search")
        #expect(tools[0]["input_schema"] != nil)
        let choice = try #require(obj["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "any")
        #expect(choice["disable_parallel_tool_use"] as? Bool == true)
    }

    @Test func reasoningEffortBecomesThinking() throws {
        let req = ChatRequest(
            model: "claude",
            input: [.message(role: .user, content: [.inputText("x")])],
            reasoningEffort: .high
        )
        let obj = try encodeToObject(req)
        let thinking = try #require(obj["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "enabled")
        #expect(thinking["budget_tokens"] as? Int == AnthropicMessagesRequestEncoder.thinkingBudget(for: .high))
    }

    @Test func imageDataBecomesBase64Source() throws {
        let req = ChatRequest(
            model: "claude",
            input: [.message(role: .user, content: [.inputImageData(base64: "QUJD", mimeType: "image/png")])]
        )
        let obj = try encodeToObject(req)
        let block = try #require(((obj["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first)
        #expect(block["type"] as? String == "image")
        let source = try #require(block["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == "QUJD")
    }
}

@Suite("AnthropicMessagesProvider.decodeModels")
struct AnthropicModelDecodeTests {
    @Test func decodesModelsWithCatalogWindows() throws {
        let json = #"""
        {"data":[{"type":"model","id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5"},{"type":"model","id":"claude-opus-4-1","display_name":"Claude Opus 4.1"}],"has_more":false,"last_id":"claude-opus-4-1"}
        """#
        let (models, hasMore, lastID) = try AnthropicMessagesProvider.decodeModels(Data(json.utf8))
        #expect(models.count == 2)
        #expect(models[0].id == "claude-sonnet-4-5")
        #expect(models[0].displayName == "Claude Sonnet 4.5")
        #expect(models[0].contextWindow == 1_000_000)   // claude-sonnet-4 prefix
        #expect(models[1].contextWindow == 200_000)      // claude-opus-4 prefix
        #expect(hasMore == false)
        #expect(lastID == "claude-opus-4-1")
    }

    @Test func reportsPagination() throws {
        let json = #"{"data":[{"type":"model","id":"claude-haiku-4"}],"has_more":true,"last_id":"claude-haiku-4"}"#
        let (models, hasMore, lastID) = try AnthropicMessagesProvider.decodeModels(Data(json.utf8))
        #expect(models[0].displayName == "claude-haiku-4")  // falls back to id
        #expect(hasMore == true)
        #expect(lastID == "claude-haiku-4")
    }
}

@Suite("ProviderRecord apiKind back-compat")
struct ProviderRecordAPIKindTests {
    private func codec() -> (JSONEncoder, JSONDecoder) {
        (JSONEncoder(), JSONDecoder())
    }

    @Test func oldRecordWithoutAPIKindDecodesAsOpenAI() throws {
        // A state file written before apiKind existed.
        let json = #"{"id":"p","displayName":"P","baseURL":"https:\/\/host\/v1"}"#
        let (_, d) = codec()
        let rec = try d.decode(ProviderRecord.self, from: Data(json.utf8))
        #expect(rec.apiKind == .openAIResponses)
    }

    @Test func anthropicRecordRoundTrips() throws {
        let (e, d) = codec()
        let rec = ProviderRecord(
            id: .init(rawValue: "claude"),
            displayName: "Claude",
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            apiKind: .anthropicMessages
        )
        let back = try d.decode(ProviderRecord.self, from: try e.encode(rec))
        #expect(back.apiKind == .anthropicMessages)
    }

    @Test func apiKindDefaultsAndHelpers() {
        #expect(LLMAPIKind.anthropicMessages.defaultBaseURL == "https://api.anthropic.com/v1")
        #expect(LLMAPIKind.openAIResponses.defaultBaseURL == "https://")
        #expect(LLMAPIKind.allCases.count == 2)
    }
}

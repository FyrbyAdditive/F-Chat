// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders
@testable import FChatCore

@Suite("OpenAIResponsesEventDecoder")
struct OpenAIResponsesEventDecoderTests {
    let decoder = OpenAIResponsesEventDecoder()

    @Test func responseCreated() throws {
        let sse = SSEEvent(event: "response.created", data: #"{"type":"response.created","response":{"id":"resp_123"}}"#)
        let event = try decoder.decode(sse)
        guard case .responseStarted(let id) = event else { Issue.record("expected .responseStarted, got \(String(describing: event))"); return }
        #expect(id == "resp_123")
    }

    @Test func textDelta() throws {
        let sse = SSEEvent(event: "response.output_text.delta", data: #"{"type":"response.output_text.delta","item_id":"item_1","delta":"Hel"}"#)
        let event = try decoder.decode(sse)
        guard case .textDelta(let item, let delta) = event else { Issue.record("expected .textDelta"); return }
        #expect(item == "item_1")
        #expect(delta == "Hel")
    }

    @Test func textCompleted() throws {
        let sse = SSEEvent(event: "response.output_text.done", data: #"{"type":"response.output_text.done","item_id":"item_1","text":"Hello"}"#)
        let event = try decoder.decode(sse)
        guard case .textCompleted(let item, let full) = event else { Issue.record("expected .textCompleted"); return }
        #expect(item == "item_1")
        #expect(full == "Hello")
    }

    @Test func reasoningSummaryDelta() throws {
        let sse = SSEEvent(event: "response.reasoning_summary_text.delta", data: #"{"type":"response.reasoning_summary_text.delta","item_id":"r1","delta":"Thinking"}"#)
        let event = try decoder.decode(sse)
        guard case .reasoningSummaryDelta(let item, let delta) = event else { Issue.record("expected .reasoningSummaryDelta"); return }
        #expect(item == "r1")
        #expect(delta == "Thinking")
    }

    @Test func vLLMStyleFunctionCallArgsResolveCallIDFromItemID() throws {
        // vLLM emits .delta / .done events WITHOUT a `call_id` field — only
        // `item_id`. The decoder must remember the mapping from the prior
        // `output_item.added` and project the canonical call_id forward.
        let started = SSEEvent(event: "response.output_item.added", data: #"{"type":"response.output_item.added","item":{"id":"be324","type":"function_call","name":"web_search","call_id":"call_xyz","arguments":"","status":"in_progress"}}"#)
        let startEvent = try decoder.decode(started)
        guard case .toolCallStarted(_, let startedCallID, _) = startEvent else { Issue.record("expected toolCallStarted"); return }
        #expect(startedCallID == "call_xyz")

        let delta = SSEEvent(event: "response.function_call_arguments.delta", data: #"{"type":"response.function_call_arguments.delta","item_id":"be324","delta":"{\"q\":\"x\"}"}"#)
        let deltaEvent = try decoder.decode(delta)
        guard case .toolCallArgumentsDelta(_, let deltaCallID, let deltaText) = deltaEvent else { Issue.record("expected toolCallArgumentsDelta"); return }
        #expect(deltaCallID == "call_xyz")
        #expect(deltaText == #"{"q":"x"}"#)

        let done = SSEEvent(event: "response.function_call_arguments.done", data: #"{"type":"response.function_call_arguments.done","item_id":"be324","arguments":"{\"q\":\"x\"}"}"#)
        let doneEvent = try decoder.decode(done)
        guard case .toolCallCompleted(_, let doneCallID, let doneName, _) = doneEvent else { Issue.record("expected toolCallCompleted"); return }
        #expect(doneCallID == "call_xyz")
        #expect(doneName == "web_search")
    }

    @Test func functionCallArgsDeltaAndDone() throws {
        let started = SSEEvent(event: "response.output_item.added", data: #"{"type":"response.output_item.added","item":{"id":"f1","type":"function_call","name":"web_search","call_id":"call_abc"}}"#)
        let startEvent = try decoder.decode(started)
        guard case .toolCallStarted(_, let cid1, let name) = startEvent else { Issue.record("expected toolCallStarted"); return }
        #expect(cid1 == "call_abc")
        #expect(name == "web_search")

        let delta = SSEEvent(event: "response.function_call_arguments.delta", data: #"{"type":"response.function_call_arguments.delta","item_id":"f1","call_id":"call_abc","delta":"{\"q\":"}"#)
        let deltaEvent = try decoder.decode(delta)
        guard case .toolCallArgumentsDelta(_, let cid2, let d) = deltaEvent else { Issue.record("expected toolCallArgumentsDelta"); return }
        #expect(cid2 == "call_abc")
        #expect(d == #"{"q":"#)

        let done = SSEEvent(event: "response.function_call_arguments.done", data: #"{"type":"response.function_call_arguments.done","item_id":"f1","call_id":"call_abc","name":"web_search","arguments":"{\"q\":\"swift\"}"}"#)
        let doneEvent = try decoder.decode(done)
        guard case .toolCallCompleted(_, let cid3, let n, let args) = doneEvent else { Issue.record("expected toolCallCompleted"); return }
        #expect(cid3 == "call_abc")
        #expect(n == "web_search")
        #expect(args == #"{"q":"swift"}"#)
    }

    @Test func completedWithUsage() throws {
        let sse = SSEEvent(event: "response.completed", data: #"{"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":34,"reasoning_tokens":5,"input_tokens_details":{"cached_tokens":2}}}}"#)
        let event = try decoder.decode(sse)
        guard case .usage(let u) = event else { Issue.record("expected usage"); return }
        #expect(u.inputTokens == 12)
        #expect(u.outputTokens == 34)
        #expect(u.reasoningTokens == 5)
        #expect(u.cachedInputTokens == 2)
    }

    @Test func errorEvent() throws {
        let sse = SSEEvent(event: "response.failed", data: #"{"type":"response.failed","error":{"message":"bad","code":"E1"}}"#)
        let event = try decoder.decode(sse)
        guard case .responseError(let msg, let code) = event else { Issue.record("expected responseError"); return }
        #expect(msg == "bad")
        #expect(code == "E1")
    }

    @Test func unknownEventReturnsNil() throws {
        let sse = SSEEvent(event: "response.something_new", data: #"{"type":"response.something_new"}"#)
        let event = try decoder.decode(sse)
        #expect(event == nil)
    }

    @Test func inferTypeFromDataWhenEventFieldMissing() throws {
        let sse = SSEEvent(event: nil, data: #"{"type":"response.created","response":{"id":"resp_x"}}"#)
        let event = try decoder.decode(sse)
        guard case .responseStarted(let id) = event else { Issue.record("expected responseStarted"); return }
        #expect(id == "resp_x")
    }
}

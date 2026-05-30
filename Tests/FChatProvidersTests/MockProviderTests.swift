// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders
@testable import FChatCore

@Suite("MockLLMProvider")
struct MockProviderTests {
    @Test func streamsScriptedEventsInOrder() async throws {
        let provider = MockLLMProvider(script: [
            .responseStarted(id: "r1"),
            .textDelta(itemID: "i1", delta: "Hello "),
            .textDelta(itemID: "i1", delta: "world"),
            .completed,
        ])
        let request = ChatRequest(model: "m", input: [.message(role: .user, content: [.inputText("hi")])])
        var events: [StreamEvent] = []
        for try await event in provider.streamResponse(request) {
            events.append(event)
        }
        #expect(events.count == 4)
        guard case .responseStarted(let id) = events[0] else { Issue.record("expected responseStarted"); return }
        #expect(id == "r1")
    }

    @Test func recordsRequestsAndAdvancesScripts() async throws {
        let provider = MockLLMProvider(script: [.textDelta(itemID: "i", delta: "A"), .completed])
        await provider.queueScript([.textDelta(itemID: "i", delta: "B"), .completed])
        let req1 = ChatRequest(model: "m", input: [.message(role: .user, content: [.inputText("first")])])
        let req2 = ChatRequest(model: "m", input: [.message(role: .user, content: [.inputText("second")])])

        var collected: [String] = []
        for try await event in provider.streamResponse(req1) {
            if case .textDelta(_, let d) = event { collected.append(d) }
        }
        for try await event in provider.streamResponse(req2) {
            if case .textDelta(_, let d) = event { collected.append(d) }
        }
        #expect(collected == ["A", "B"])
        let received = await provider.receivedRequests
        #expect(received.count == 2)
    }

    @Test func defaultEmbeddingsReturnDeterministicVectors() async throws {
        let provider = MockLLMProvider()
        let vectors = try await provider.embed(["abc", "wxyz"], model: "any")
        #expect(vectors.count == 2)
        #expect(vectors[0].count == 4)
        #expect(vectors[0].first == 3.0)
        #expect(vectors[1].first == 4.0)
    }
}

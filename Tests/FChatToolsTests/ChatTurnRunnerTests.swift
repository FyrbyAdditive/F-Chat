// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatProviders
@testable import FChatTools

@Suite("ChatTurnRunner", .serialized)
struct ChatTurnRunnerTests {
    @Test func plainTextResponseEndsAfterOneTurn() async throws {
        let provider = MockLLMProvider(script: [
            .responseStarted(id: "r1"),
            .textDelta(itemID: "i1", delta: "Hi"),
            .completed,
        ])
        let runner = ChatTurnRunner(provider: provider, registry: ToolRegistry())
        let initial = ChatRequest(model: "m", input: [.message(role: .user, content: [.inputText("hi")])])
        var events: [ChatTurnEvent] = []
        for try await event in runner.run(initial: initial) {
            events.append(event)
        }
        guard case .completed = events.last else { Issue.record("expected .completed last"); return }
        let receivedCount = await provider.receivedRequests.count
        #expect(receivedCount == 1)
    }

    @Test func toolCallTriggersSecondTurnWithFunctionOutput() async throws {
        let provider = MockLLMProvider(script: [
            .responseStarted(id: "r1"),
            .toolCallStarted(itemID: "f1", callID: "call_1", name: "echo"),
            .toolCallArgumentsDelta(itemID: "f1", callID: "call_1", delta: #"{"v":"hello"}"#),
            .toolCallCompleted(itemID: "f1", callID: "call_1", name: "echo", arguments: #"{"v":"hello"}"#),
            .completed,
        ])
        await provider.queueScript([
            .responseStarted(id: "r2"),
            .textDelta(itemID: "i1", delta: "Got it"),
            .completed,
        ])

        let registry = ToolRegistry()
        await registry.register(EchoTool(name: "echo"))

        let runner = ChatTurnRunner(provider: provider, registry: registry)
        let initial = ChatRequest(model: "m", input: [.message(role: .user, content: [.inputText("hi")])])
        var events: [ChatTurnEvent] = []
        for try await event in runner.run(initial: initial) {
            events.append(event)
        }

        let received = await provider.receivedRequests
        #expect(received.count == 2)

        let secondInput = received[1].input
        var sawCall = false, sawOutput = false, sawInitialMessage = false
        for item in secondInput {
            if case .message = item { sawInitialMessage = true }
            if case .functionCall(let cid, let name, _) = item, cid == "call_1", name == "echo" { sawCall = true }
            if case .functionCallOutput(let cid, let outputJSON) = item, cid == "call_1" {
                sawOutput = true
                #expect(outputJSON.contains("hello"))
            }
        }
        // Stateless mode: the second turn must include the original user
        // message plus the function call + output, and must NOT chain via
        // previous_response_id (vLLM and similar self-hosted servers don't
        // persist responses across requests).
        #expect(sawInitialMessage && sawCall && sawOutput)
        #expect(received[1].previousResponseID == nil)
        #expect(received[1].store == false)

        // We should see a toolResult event surfaced to the consumer.
        let sawToolResult = events.contains { if case .toolResult(_, _) = $0 { return true } else { return false } }
        #expect(sawToolResult)
    }

    @Test func maxIterationsGuardTrips() async throws {
        // Provider always emits a tool call, never .completed without one. Should hit the cap.
        let infinite = MockLLMProvider(script: [
            .toolCallStarted(itemID: "f", callID: "c", name: "echo"),
            .toolCallCompleted(itemID: "f", callID: "c", name: "echo", arguments: "{}"),
            .completed,
        ])
        // Queue 10 identical follow-ups so successive turns also see one.
        for _ in 0..<10 {
            await infinite.queueScript([
                .toolCallStarted(itemID: "f", callID: "c", name: "echo"),
                .toolCallCompleted(itemID: "f", callID: "c", name: "echo", arguments: "{}"),
                .completed,
            ])
        }
        let registry = ToolRegistry()
        await registry.register(EchoTool(name: "echo"))

        let runner = ChatTurnRunner(provider: infinite, registry: registry, maxIterations: 3)
        let initial = ChatRequest(model: "m", input: [.message(role: .user, content: [.inputText("hi")])])
        var lastEvent: ChatTurnEvent?
        for try await event in runner.run(initial: initial) { lastEvent = event }
        guard case .maxIterationsReached = lastEvent else { Issue.record("expected maxIterationsReached, got \(String(describing: lastEvent))"); return }

        let received = await infinite.receivedRequests
        #expect(received.count == 3)
    }
}

import Testing
import Foundation
@testable import FChatProviders
@testable import FChatCore

@Suite("RequestPayloadBuilder")
struct RequestPayloadBuilderTests {
    let builder: RequestPayloadBuilder

    init() {
        // Use the heuristic tokenizer so tests are deterministic without
        // depending on the bundled BPE vocab files.
        builder = RequestPayloadBuilder(tokenizer: HeuristicTokenizer())
    }

    private func makeConversation(messages: [Message]) -> Conversation {
        Conversation(
            title: "test",
            settings: ChatSettings(model: "test", providerID: .init(rawValue: "test")),
            messages: messages
        )
    }

    @Test func assemblesUserAndAssistantTextOnly() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("hi")]),
            Message(role: .assistant, contentItems: [.text("hello")]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "second")
        #expect(items.count == 3)
        guard case .message(let role, _) = items[0] else { Issue.record("bad first"); return }
        #expect(role == .user)
        guard case .message(let last, let content) = items.last,
              case .inputText(let text) = content.first
        else { Issue.record("bad last"); return }
        #expect(last == .user)
        #expect(text == "second")
    }

    @Test func includesToolCallsAndResultsInHistory() {
        // The bug fix: tool calls + results MUST appear in re-sent history
        // so the model can reference its own prior tool output.
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("search swift news")]),
            Message(role: .assistant, contentItems: [
                .toolCall(ToolCallRecord(id: "call_1", name: "web_search", argumentsJSON: #"{"q":"swift"}"#, status: .succeeded)),
                .toolResult(ToolResultRecord(callID: "call_1", outputJSON: "[results]")),
                .text("Here you go"),
            ]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "")
        let kinds = items.map { item -> String in
            switch item {
            case .message: return "message"
            case .functionCall: return "functionCall"
            case .functionCallOutput: return "functionCallOutput"
            case .reasoning: return "reasoning"
            }
        }
        #expect(kinds.contains("functionCall"))
        #expect(kinds.contains("functionCallOutput"))
    }

    @Test func reasoningSummariesAreStrippedFromPayload() {
        let convo = makeConversation(messages: [
            Message(role: .assistant, contentItems: [
                .reasoningSummary("I think therefore I am"),
                .text("Answer is 42"),
            ]),
        ])
        let items = builder.assemble(conversation: convo, draftUserText: "")
        // Only one message item containing the text, no reasoning leaked.
        #expect(items.count == 1)
        guard case .message(_, let content) = items[0],
              case .inputText(let text) = content.first
        else { Issue.record("bad"); return }
        #expect(text == "Answer is 42")
    }

    @Test func summaryPrefacesKeptHistory() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("old 1")]),
            Message(role: .user, contentItems: [.text("old 2")]),
            Message(role: .user, contentItems: [.text("recent 1")]),
            Message(role: .user, contentItems: [.text("recent 2")]),
        ])
        let items = builder.assemble(
            conversation: convo,
            draftUserText: "new draft",
            summary: "Earlier: user said hi twice",
            keepRange: 2..<4
        )
        // First item should be the summary system message.
        guard case .message(let firstRole, let firstContent) = items[0],
              case .inputText(let firstText) = firstContent.first
        else { Issue.record("expected system summary first"); return }
        #expect(firstRole == .system)
        #expect(firstText.contains("Summary of earlier conversation"))
        #expect(firstText.contains("Earlier: user said hi twice"))
        // Old 1 / Old 2 should NOT appear; recent 1, recent 2, draft should.
        let bodies = items.compactMap { item -> String? in
            if case .message(_, let content) = item,
               case .inputText(let t) = content.first { return t }
            return nil
        }
        #expect(bodies.contains(where: { $0 == "recent 1" }))
        #expect(bodies.contains(where: { $0 == "recent 2" }))
        #expect(bodies.contains(where: { $0 == "new draft" }))
        #expect(!bodies.contains(where: { $0 == "old 1" }))
    }

    @Test func projectionMatchesHeuristicCounts() {
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text(String(repeating: "x", count: 80))]),
        ])
        let projection = builder.project(
            conversation: convo,
            draftUserText: String(repeating: "y", count: 40),
            instructions: String(repeating: "z", count: 20),
            toolDefinitions: []
        )
        // HeuristicTokenizer = max(1, chars/4); plus per-message envelope of 3.
        #expect(projection.draftTokens == 10)
        #expect(projection.systemTokens == 5)
        #expect(projection.historyTokens >= 20)
        #expect(projection.totalTokens > projection.draftTokens)
    }
}

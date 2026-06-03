// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore

@Suite("Conversation search")
struct ConversationSearchTests {

    private func convo(_ title: String, _ texts: [String]) -> Conversation {
        Conversation(
            title: title,
            settings: ChatSettings(model: "test", providerID: .init(rawValue: "test")),
            messages: texts.map { Message(role: .user, contentItems: [.text($0)]) }
        )
    }

    private func sample() -> [Conversation] {
        [
            convo("Trip planning", ["What's the weather in Tokyo?", "Pack an umbrella"]),
            convo("Swift refactor", ["How do I use actors?"]),
            convo("Grocery list", ["milk, eggs, bread"]),
        ]
    }

    @Test func emptyQueryReturnsAll() {
        #expect(conversationsMatching(query: "", in: sample()).count == 3)
        #expect(conversationsMatching(query: "   ", in: sample()).count == 3)
    }

    @Test func matchesByTitle() {
        let r = conversationsMatching(query: "refactor", in: sample())
        #expect(r.count == 1)
        #expect(r.first?.title == "Swift refactor")
    }

    @Test func matchesByMessageText() {
        let r = conversationsMatching(query: "umbrella", in: sample())
        #expect(r.count == 1)
        #expect(r.first?.title == "Trip planning")
    }

    @Test func caseInsensitive() {
        #expect(conversationsMatching(query: "TOKYO", in: sample()).count == 1)
        #expect(conversationsMatching(query: "GrOcErY", in: sample()).count == 1)
    }

    @Test func noMatchReturnsEmpty() {
        #expect(conversationsMatching(query: "nonexistent xyzzy", in: sample()).isEmpty)
    }

    @Test func preservesOrder() {
        let convos = [convo("alpha", ["shared"]), convo("beta", ["shared"])]
        let r = conversationsMatching(query: "shared", in: convos)
        #expect(r.map(\.title) == ["alpha", "beta"])
    }
}

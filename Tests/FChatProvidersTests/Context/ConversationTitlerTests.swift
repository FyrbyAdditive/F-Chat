// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders
@testable import FChatCore

@Suite("ConversationTitler")
struct ConversationTitlerTests {

    // MARK: - clean(_:)

    @Test func cleanStripsStraightQuotes() throws {
        #expect(try ConversationTitler.clean("\"Foo Bar\"") == "Foo Bar")
    }

    @Test func cleanStripsSmartQuotes() throws {
        #expect(try ConversationTitler.clean("\u{201C}Foo Bar\u{201D}") == "Foo Bar")
        #expect(try ConversationTitler.clean("\u{2018}Foo Bar\u{2019}") == "Foo Bar")
    }

    @Test func cleanStripsBackticks() throws {
        #expect(try ConversationTitler.clean("`Foo Bar`") == "Foo Bar")
    }

    @Test func cleanStripsTrailingPunctuation() throws {
        #expect(try ConversationTitler.clean("Foo Bar.") == "Foo Bar")
        #expect(try ConversationTitler.clean("Foo Bar!") == "Foo Bar")
        #expect(try ConversationTitler.clean("Foo Bar?") == "Foo Bar")
    }

    @Test func cleanTakesFirstNonEmptyLine() throws {
        let raw = "\n\nFirst Real Line\nIgnored second line\nIgnored third"
        #expect(try ConversationTitler.clean(raw) == "First Real Line")
    }

    @Test func cleanCapsAt60Chars() throws {
        let raw = String(repeating: "Aa", count: 60) // 120 chars, no spaces
        let cleaned = try ConversationTitler.clean(raw)
        #expect(cleaned.count <= ConversationTitler.maxTitleLength)
    }

    @Test func cleanPrefersWordBoundaryWhenTruncating() throws {
        // 80 chars with spaces; should chop at the last space within the cap.
        let raw = "The Quick Brown Fox Jumps Over The Lazy Dog And Then Runs Away From The Hounds"
        let cleaned = try ConversationTitler.clean(raw)
        #expect(cleaned.count <= ConversationTitler.maxTitleLength)
        // No trailing whitespace.
        #expect(cleaned.last != " ")
        // Boundary cut: shouldn't end in a partial word — assert the cleaned
        // string is a prefix of raw on a space.
        let boundary = raw.prefix(cleaned.count + 1)
        if boundary.count > cleaned.count {
            #expect(boundary.last == " ")
        }
    }

    @Test func cleanThrowsOnEmptyInput() {
        #expect(throws: TitlerError.self) {
            try ConversationTitler.clean("")
        }
        #expect(throws: TitlerError.self) {
            try ConversationTitler.clean("   \n\n   ")
        }
    }

    @Test func cleanUnwrapsRepeatedQuoteLayers() throws {
        // Models sometimes double-wrap.
        #expect(try ConversationTitler.clean("\"`Foo`\"") == "Foo")
    }

    // MARK: - end-to-end via MockLLMProvider

    @Test func titleFromStreamAssemblesAndCleansResponse() async throws {
        let provider = MockLLMProvider(script: [
            .responseStarted(id: "r1"),
            .textDelta(itemID: "i1", delta: "\"Sweden Capital Lookup.\""),
            .completed,
        ])
        let titler = ConversationTitler(provider: provider, modelID: "test-model")
        let title = try await titler.title(
            forFirstUser: "What's the capital of Sweden?",
            firstAssistant: "Stockholm."
        )
        #expect(title == "Sweden Capital Lookup")
    }

    @Test func titlePropagatesProviderError() async throws {
        let provider = MockLLMProvider(script: [
            .responseError(message: "service unavailable", code: nil),
        ])
        let titler = ConversationTitler(provider: provider, modelID: "test-model")
        await #expect(throws: TitlerError.self) {
            try await titler.title(forFirstUser: "u", firstAssistant: "a")
        }
    }

    @Test func titleRejectsWhitespaceOnlyResponse() async throws {
        let provider = MockLLMProvider(script: [
            .textDelta(itemID: "i", delta: "   "),
            .completed,
        ])
        let titler = ConversationTitler(provider: provider, modelID: "test-model")
        await #expect(throws: TitlerError.self) {
            try await titler.title(forFirstUser: "u", firstAssistant: "a")
        }
    }
}

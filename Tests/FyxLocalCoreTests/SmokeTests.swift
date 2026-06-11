// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore

@Suite("Core smoke")
struct CoreSmokeTests {
    @Test func appIdentifierMatches() {
        #expect(FyxLocal.appIdentifier == "com.fyrbyadditive.fyxlocal")
    }

    @Test func messageContentRoundTripsThroughJSON() throws {
        let items: [MessageContent] = [
            .text("hello"),
            .reasoningSummary("thinking..."),
            .thinking(text: "signed thinking", signature: "sigXYZ"),
            .redactedThinking(data: "OPAQUE=="),
            .toolCall(ToolCallRecord(id: "call_1", name: "web_search", argumentsJSON: #"{"query":"x"}"#)),
            .toolResult(ToolResultRecord(callID: "call_1", outputJSON: "[]", isError: false, display: .markdown)),
        ]
        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([MessageContent].self, from: data)
        #expect(decoded == items)
    }

    @Test func oldShapeReasoningSummaryStillDecodes() throws {
        // The exact JSON shape state.json has always written for reasoning —
        // adding the signed .thinking case must not disturb it.
        let json = #"[{"type":"reasoningSummary","text":"old thoughts"}]"#
        let decoded = try JSONDecoder().decode([MessageContent].self, from: Data(json.utf8))
        #expect(decoded == [.reasoningSummary("old thoughts")])
    }

    @Test func plainTextOnlyConcatenatesTextItems() {
        let m = Message(role: .assistant, contentItems: [
            .text("a"),
            .reasoningSummary("hidden"),
            .text("b"),
        ])
        #expect(m.plainText == "a\nb")
    }

    @Test(arguments: [
        ("en", PromptLanguage.english),       // bare en (no region) → base/US
        ("en_US", PromptLanguage.english),    // US → base
        ("en_AU", PromptLanguage.english),    // other English regions → base
        ("en_GB", PromptLanguage.englishGB),  // British → en-GB
        ("sv", PromptLanguage.swedish),
        ("sv_SE", PromptLanguage.swedish),    // region ignored for non-English
        ("da_DK", PromptLanguage.danish),
        ("de", PromptLanguage.english),       // unsupported → base fallback
    ])
    func resolvesPromptLanguageFromLocale(code: String, expected: PromptLanguage) {
        let locale = Locale(identifier: code)
        #expect(PromptLanguage.resolve(from: locale) == expected)
    }
}

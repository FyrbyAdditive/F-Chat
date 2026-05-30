// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore

@Suite("LocalizedSystemPrompt")
struct LocalizedSystemPromptTests {
    @Test func englishContainsFChatAndDoesNotMentionSwedish() {
        let prompt = LocalizedSystemPrompt(language: .english).render()
        #expect(prompt.contains("F-Chat"))
        #expect(prompt.lowercased().contains("concise"))
        #expect(!prompt.contains("svenska"))
    }

    @Test func swedishAnchorPhrasePresent() {
        let prompt = LocalizedSystemPrompt(language: .swedish).render()
        #expect(prompt.contains("F-Chat"))
        #expect(prompt.contains("svenska"))
    }

    @Test func skillsSectionAppearsWhenSkillsPresent() {
        let prompt = LocalizedSystemPrompt(
            language: .english,
            skills: [
                .init(name: "pdf-tools", description: "Work with PDFs."),
                .init(name: "charts", description: "Make charts."),
            ]
        ).render()
        #expect(prompt.contains("pdf-tools"))
        #expect(prompt.contains("Work with PDFs."))
        #expect(prompt.contains("run_code"))
        #expect(prompt.contains("SKILL.md"))
    }

    @Test func noSkillsSectionWhenEmpty() {
        let prompt = LocalizedSystemPrompt(language: .english, skills: []).render()
        #expect(!prompt.contains("run_code"))
        #expect(!prompt.lowercased().contains("the following skills"))
    }

    @Test func toolGuidanceTogglesSection() {
        let withTools = LocalizedSystemPrompt(language: .english, includeToolGuidance: true).render()
        let withoutTools = LocalizedSystemPrompt(language: .english, includeToolGuidance: false).render()
        #expect(withTools.contains("tools"))
        #expect(!withoutTools.contains("provided tools"))
    }

    @Test func ragGuidanceTogglesSection() {
        let withRAG = LocalizedSystemPrompt(language: .english, includeRAGGuidance: true).render()
        let withoutRAG = LocalizedSystemPrompt(language: .english, includeRAGGuidance: false).render()
        #expect(withRAG.contains("rag_search"))
        #expect(!withoutRAG.contains("rag_search"))
    }

    @Test func customSuffixAppended() {
        let prompt = LocalizedSystemPrompt(
            language: .english,
            customSuffix: "Always end answers with a haiku."
        ).render()
        #expect(prompt.hasSuffix("Always end answers with a haiku."))
    }

    @Test(arguments: PromptLanguage.allCases)
    func allLanguagesProduceNonEmptyOutputAcrossFlagMatrix(language: PromptLanguage) {
        for tools in [false, true] {
            for rag in [false, true] {
                let prompt = LocalizedSystemPrompt(
                    language: language,
                    includeToolGuidance: tools,
                    includeRAGGuidance: rag
                ).render()
                #expect(!prompt.isEmpty)
                #expect(prompt.count > 50)
            }
        }
    }

    /// Regression guard for the vLLM prefix-cache fix: the system prompt
    /// must never contain a per-send timestamp or per-send date. The full
    /// instructions string sent to the server is just this prompt today
    /// (ChatViewModel.composeInstructions), so if any future change adds
    /// a TemporalContext.render() back into the prompt itself, this test
    /// fails and the cache invalidator returns.
    @Test func systemPromptContainsNoPerSendTimestamps() {
        for language in PromptLanguage.allCases {
            let prompt = LocalizedSystemPrompt(
                language: language,
                includeToolGuidance: true,
                includeRAGGuidance: true
            ).render()
            // ISO-8601 / second-precision time markers that would change
            // every send and break vLLM's prefix cache.
            #expect(!prompt.contains("Machine-readable"))
            #expect(!prompt.contains("ISO"))
            // Clock-style time references that drift by the minute.
            #expect(!prompt.contains("AM"))
            #expect(!prompt.contains("PM"))
            // A bare digit-colon-digit pattern (e.g. "10:34") would also
            // be a time. Tolerate colons used in punctuation elsewhere by
            // explicitly looking for the dd:dd shape.
            let timePattern = try? NSRegularExpression(pattern: #"\d{1,2}:\d{2}"#)
            let range = NSRange(prompt.startIndex..., in: prompt)
            let matches = timePattern?.numberOfMatches(in: prompt, range: range) ?? 0
            #expect(matches == 0, "prompt contained a clock-style time pattern; would invalidate prefix cache")
        }
    }
}

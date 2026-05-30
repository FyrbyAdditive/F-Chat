// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore

@Suite("LocalizedSystemPrompt — basePromptOverride")
struct SystemPromptCompositionTests {
    /// Migration regression: with no override (the Default agent's shape),
    /// the rendered prompt must be byte-identical to the pre-agents flow.
    /// Every pre-existing chat depends on this — if the rendered prompt
    /// shifts even by whitespace, the model's behaviour can drift.
    @Test func defaultAgentRendersByteIdenticalToPreFeatureOutput() {
        let preFeature = LocalizedSystemPrompt(
            language: .english,
            includeToolGuidance: true,
            includeRAGGuidance: false
        ).render()

        let withDefault = LocalizedSystemPrompt(
            language: .english,
            includeToolGuidance: true,
            includeRAGGuidance: false,
            basePromptOverride: nil
        ).render()

        #expect(preFeature == withDefault)
    }

    @Test func defaultAgentRendersByteIdenticalInSwedishToo() {
        let preFeature = LocalizedSystemPrompt(
            language: .swedish,
            includeToolGuidance: true,
            includeRAGGuidance: true
        ).render()

        let withDefault = LocalizedSystemPrompt(
            language: .swedish,
            includeToolGuidance: true,
            includeRAGGuidance: true,
            basePromptOverride: nil
        ).render()

        #expect(preFeature == withDefault)
    }

    /// Custom agent: basePromptOverride replaces the F-Chat preamble at
    /// the head of the prompt; tool / RAG guidance continues to be
    /// auto-appended so tools and attached collections keep working.
    @Test func customBasePromptReplacesPreambleAndKeepsGuidance() {
        let custom = "You are a senior Python engineer who writes idiomatic, tested code."
        let rendered = LocalizedSystemPrompt(
            language: .english,
            includeToolGuidance: true,
            includeRAGGuidance: true,
            basePromptOverride: custom
        ).render()

        #expect(rendered.hasPrefix(custom))
        // The default preamble starts with "You are F-Chat" — must NOT
        // be present in a custom-agent render.
        #expect(!rendered.contains("You are F-Chat"))
        // Tool guidance is still appended.
        #expect(rendered.contains("You may call the provided tools"))
        // RAG guidance is still appended when enabled.
        #expect(rendered.contains("rag_search"))
    }

    @Test func customBasePromptDisablesGuidanceWhenFlagsAreOff() {
        let custom = "You are a haiku writer. Reply in haiku."
        let rendered = LocalizedSystemPrompt(
            language: .english,
            includeToolGuidance: false,
            includeRAGGuidance: false,
            basePromptOverride: custom
        ).render()

        #expect(rendered == custom)
    }

    /// Empty / whitespace-only override is treated as no override — fall
    /// back to the built-in preamble. Guards against a user clearing the
    /// prompt field by accident and ending up with a no-system-prompt
    /// chat.
    @Test func emptyOverrideFallsBackToBuiltIn() {
        let renderedWithEmpty = LocalizedSystemPrompt(
            language: .english,
            includeToolGuidance: true,
            basePromptOverride: ""
        ).render()
        let renderedWithNil = LocalizedSystemPrompt(
            language: .english,
            includeToolGuidance: true,
            basePromptOverride: nil
        ).render()
        #expect(renderedWithEmpty == renderedWithNil)
    }

    /// The built-in preamble accessor must return exactly the same text
    /// the renderer falls back to. AgentsTab seeds its TextEditor from
    /// this value when the Default agent hasn't been overridden — if
    /// these two ever drift, the user would see a different prompt in
    /// the editor than the one actually being sent to the model.
    @Test func builtInPreambleMatchesRenderedDefault() {
        for language in [PromptLanguage.english, .swedish] {
            let preamble = LocalizedSystemPrompt.builtInPreamble(for: language)
            let renderedDefault = LocalizedSystemPrompt(
                language: language,
                includeToolGuidance: false,
                includeRAGGuidance: false,
                basePromptOverride: nil
            ).render()
            #expect(preamble == renderedDefault)
        }
    }

    @Test func customSuffixStillAppendsAfterCustomBase() {
        let rendered = LocalizedSystemPrompt(
            language: .english,
            includeToolGuidance: true,
            customSuffix: "Always sign off with: cheers.",
            basePromptOverride: "You are a butler."
        ).render()
        #expect(rendered.hasPrefix("You are a butler."))
        #expect(rendered.hasSuffix("Always sign off with: cheers."))
    }
}

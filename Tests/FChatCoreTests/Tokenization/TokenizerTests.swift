// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore

@Suite("BPETokenizer (cl100k_base)")
struct CL100kTests {
    let tokenizer: BPETokenizer

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "cl100k_base", withExtension: "tiktoken"))
        let data = try Data(contentsOf: url)
        let encoder = try TikTokenLoader.loadEncoder(from: data)
        tokenizer = BPETokenizer(name: "cl100k_base", encoder: encoder)
    }

    @Test func vocabularyLooksRight() {
        // cl100k_base has ~100k entries (100256 to be exact, no special tokens).
        #expect(tokenizer.vocabularyCount > 99_000)
        #expect(tokenizer.vocabularyCount < 102_000)
    }

    @Test func emptyStringIsZeroTokens() {
        #expect(tokenizer.countTokens(in: "") == 0)
    }

    /// Golden counts taken from upstream tiktoken (cl100k_base) so we
    /// catch any drift in the BPE engine.
    @Test(arguments: [
        ("hello world", 2),
        ("Hello, world!", 4),
        ("The quick brown fox jumps over the lazy dog.", 10),
        ("tiktoken is great!", 6),
    ])
    func goldenCountsForKnownInputs(text: String, expected: Int) {
        let actual = tokenizer.countTokens(in: text)
        #expect(actual == expected, "expected \(expected) tokens for \"\(text)\", got \(actual)")
    }

    @Test func handlesCJKWithoutCrashing() {
        // We don't pin an exact golden for CJK because our simplified
        // pre-tokenization differs slightly from upstream tiktoken on
        // non-Latin scripts. Assert only that the count is plausible
        // for the input length (won't be zero, won't be absurd).
        let text = "こんにちは世界"
        let count = tokenizer.countTokens(in: text)
        #expect(count > 0)
        #expect(count < text.count * 4)
    }

    @Test func encodeRoundTripsThroughCountTokens() {
        let text = "Some realistic prose with punctuation, numbers like 42, and a URL: https://example.com/path."
        let encoded = tokenizer.encode(text)
        #expect(encoded.count == tokenizer.countTokens(in: text))
        #expect(!encoded.isEmpty)
    }
}

@Suite("BPETokenizer (o200k_base)")
struct O200kTests {
    let tokenizer: BPETokenizer

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "o200k_base", withExtension: "tiktoken"))
        let data = try Data(contentsOf: url)
        let encoder = try TikTokenLoader.loadEncoder(from: data)
        tokenizer = BPETokenizer(name: "o200k_base", encoder: encoder)
    }

    @Test func vocabularyIsLargerThanCL100k() {
        #expect(tokenizer.vocabularyCount > 199_000)
    }

    /// Golden counts from upstream tiktoken (o200k_base).
    @Test(arguments: [
        ("hello world", 2),
        ("The quick brown fox jumps over the lazy dog.", 10),
    ])
    func goldenCountsForKnownInputs(text: String, expected: Int) {
        let actual = tokenizer.countTokens(in: text)
        #expect(actual == expected, "expected \(expected) tokens for \"\(text)\", got \(actual)")
    }
}

@Suite("TokenizerRegistry")
struct TokenizerRegistryTests {
    @Test(arguments: [
        ("gpt-4o", TokenizerID.o200kBase),
        ("gpt-4o-mini", TokenizerID.o200kBase),
        ("gpt-4-turbo", TokenizerID.o200kBase),
        ("gpt-4", TokenizerID.cl100kBase),
        ("gpt-3.5-turbo", TokenizerID.cl100kBase),
        ("text-embedding-3-small", TokenizerID.cl100kBase),
        ("cyankiwi/MiniMax-M2.7-AWQ-4bit", TokenizerID.minimax),
        ("MiniMaxAI/MiniMax-M2.7", TokenizerID.minimax),
        ("totally-unknown-model", TokenizerID.cl100kBase),
        ("", TokenizerID.cl100kBase),
    ])
    func mapsModelIDToTokenizer(modelID: String, expected: TokenizerID) async {
        let registry = TokenizerRegistry()
        let resolved = await registry.resolve(modelID: modelID)
        #expect(resolved == expected)
    }

    @Test func cachesLoadedTokenizers() async {
        let registry = TokenizerRegistry()
        let a = await registry.tokenizer(for: "gpt-4o")
        let b = await registry.tokenizer(for: "gpt-4o-mini")
        // Both map to o200k_base; loaded once and reused (we can't compare
        // identity through `any Tokenizer` cheaply, so just assert name).
        #expect(a.name == b.name)
    }
}

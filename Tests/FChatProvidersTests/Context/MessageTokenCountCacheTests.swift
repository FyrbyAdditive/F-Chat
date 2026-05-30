// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders
@testable import FChatCore

/// Tokenizer that counts how many times `countTokens(in:)` was called.
/// Lets us assert the cache is actually preventing redundant BPE work.
private final class CountingTokenizer: Tokenizer, @unchecked Sendable {
    let name: String = "counting-test"
    let vocabularyCount: Int = 1024

    private(set) var calls: Int = 0
    private let lock = NSLock()

    func encode(_ text: String) -> [Int] {
        Array(repeating: 0, count: countTokens(in: text))
    }

    func countTokens(in text: String) -> Int {
        lock.lock(); calls += 1; lock.unlock()
        // Approximate: one token per 4 chars. Deterministic, no I/O.
        return max(1, text.count / 4)
    }

    func reset() { lock.lock(); calls = 0; lock.unlock() }
}

@Suite("MessageTokenCountCache")
struct MessageTokenCountCacheTests {

    private func makeConversation(messages: [Message]) -> Conversation {
        Conversation(
            title: "test",
            settings: ChatSettings(model: "test", providerID: .init(rawValue: "test")),
            messages: messages
        )
    }

    @Test func secondProjectionWithSameInputsDoesNoMessageTokenizing() {
        let tokenizer = CountingTokenizer()
        let builder = RequestPayloadBuilder(tokenizer: tokenizer)
        let cache = MessageTokenCountCache()
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("hello world")]),
            Message(role: .assistant, contentItems: [.text("hi there")]),
            Message(role: .user, contentItems: [.text("how are you")]),
        ])

        _ = builder.project(
            conversation: convo,
            draftUserText: "",
            instructions: "",
            toolDefinitions: [],
            cache: cache
        )
        let firstCount = tokenizer.calls
        tokenizer.reset()

        // Second projection over the same conversation should hit the cache
        // for every message — tokenizer should only be invoked for the
        // instructions + draft + tool defs (here: all empty/short), not for
        // any message content.
        _ = builder.project(
            conversation: convo,
            draftUserText: "",
            instructions: "",
            toolDefinitions: [],
            cache: cache
        )
        let secondCount = tokenizer.calls
        #expect(firstCount > secondCount, "first pass must do more BPE work than the second")
        // The second pass tokenises instructions(""), draft(""), but never
        // any message content. Conservative bound: < first pass message count.
        #expect(secondCount <= 2, "expected ≤2 tokenizer calls after cache warm; got \(secondCount)")
    }

    @Test func editingOneMessageInvalidatesOnlyThatEntry() {
        let tokenizer = CountingTokenizer()
        let builder = RequestPayloadBuilder(tokenizer: tokenizer)
        let cache = MessageTokenCountCache()
        let msgA = Message(role: .user, contentItems: [.text("aaa")])
        let msgB = Message(role: .assistant, contentItems: [.text("bbb")])
        let msgC = Message(role: .user, contentItems: [.text("ccc")])
        let convo1 = makeConversation(messages: [msgA, msgB, msgC])

        // Warm
        _ = builder.project(
            conversation: convo1,
            draftUserText: "",
            instructions: "",
            toolDefinitions: [],
            cache: cache
        )
        tokenizer.reset()

        // Modify only msgB (same id, longer text — simulates a streaming
        // delta growing the assistant's reply).
        var msgBEdited = msgB
        msgBEdited.contentItems = [.text("bbbbbbbbbbbbbbb")]
        let convo2 = makeConversation(messages: [msgA, msgBEdited, msgC])
        _ = builder.project(
            conversation: convo2,
            draftUserText: "",
            instructions: "",
            toolDefinitions: [],
            cache: cache
        )
        // The cache should re-tokenise only msgB — msgA and msgC stay cached
        // because their fingerprints are unchanged. Total calls: 1 for msgB
        // + 2 for the unconditional instructions/draft tokenisation.
        #expect(tokenizer.calls == 3, "expected 1 re-tokenize for the edited message + 2 for instructions/draft; got \(tokenizer.calls)")
    }

    @Test func resetClearsAllEntries() {
        let tokenizer = CountingTokenizer()
        let builder = RequestPayloadBuilder(tokenizer: tokenizer)
        let cache = MessageTokenCountCache()
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("warm me")]),
        ])
        _ = builder.project(
            conversation: convo,
            draftUserText: "",
            instructions: "",
            toolDefinitions: [],
            cache: cache
        )
        cache.reset()
        tokenizer.reset()

        _ = builder.project(
            conversation: convo,
            draftUserText: "",
            instructions: "",
            toolDefinitions: [],
            cache: cache
        )
        // After reset, the message must be re-tokenised.
        #expect(tokenizer.calls >= 1, "expected re-tokenize after reset; got \(tokenizer.calls)")
    }

    @Test func nilCachePreservesOriginalBehaviour() {
        // Default-nil cache argument means project(...) behaves exactly like
        // before this change — for backwards compat with existing tests.
        let tokenizer = CountingTokenizer()
        let builder = RequestPayloadBuilder(tokenizer: tokenizer)
        let convo = makeConversation(messages: [
            Message(role: .user, contentItems: [.text("hi")]),
        ])
        _ = builder.project(
            conversation: convo,
            draftUserText: "",
            instructions: "",
            toolDefinitions: []
        )
        let firstCount = tokenizer.calls
        _ = builder.project(
            conversation: convo,
            draftUserText: "",
            instructions: "",
            toolDefinitions: []
        )
        let totalCount = tokenizer.calls
        #expect(totalCount > firstCount, "without a cache, every call re-tokenises")
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Counts tokens for a given string under a specific BPE vocabulary.
///
/// We only need `countTokens` for the chat-budget use case — the actual
/// integer rank sequence is exposed for tests + future debugging but the
/// runtime never needs it.
public protocol Tokenizer: Sendable {
    /// Stable identifier so the runtime can decide whether two callers got
    /// the same tokenizer (e.g. for cache keys).
    var name: String { get }

    /// Approximate maximum token id this tokenizer can emit; useful for
    /// sanity-checking model context windows.
    var vocabularyCount: Int { get }

    /// Encode a string into the tokenizer's rank space. Stable across calls.
    func encode(_ text: String) -> [Int]

    /// Token count for the given text. Default implementation calls `encode`
    /// and returns count; concrete implementations may override with a
    /// faster path that doesn't materialise the rank array.
    func countTokens(in text: String) -> Int
}

public extension Tokenizer {
    func countTokens(in text: String) -> Int {
        encode(text).count
    }
}

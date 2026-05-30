// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Last-resort lookup for context windows on hosted models whose `/models`
/// endpoint doesn't report a window field. Keyed by lower-cased model id
/// prefix, longest-match wins. Conservative on purpose — when the docs
/// give a range, we take the lower bound.
public enum KnownModelCatalog {
    /// Returns a known context window for the given model id, or nil if
    /// we don't have a hint.
    public static func contextWindow(for modelID: String) -> Int? {
        let lower = modelID.lowercased()
        for (prefix, window) in entriesByLongestPrefix {
            if lower.hasPrefix(prefix) {
                return window
            }
        }
        return nil
    }

    /// Sorted by prefix length descending so longest match wins.
    private static let entriesByLongestPrefix: [(String, Int)] = entries.sorted {
        $0.0.count > $1.0.count
    }

    /// (modelIDPrefix, contextWindow). Values from openai.com/api docs and
    /// publicly documented Anthropic/Google specs. Out-of-date entries are
    /// always recoverable by setting an explicit hard cap in Settings.
    private static let entries: [(String, Int)] = [
        // OpenAI hosted (no context_window in /models response)
        ("gpt-4o-mini", 128_000),
        ("gpt-4o", 128_000),
        ("gpt-4-turbo", 128_000),
        ("gpt-4-1106", 128_000),
        ("gpt-4-0125", 128_000),
        ("gpt-4.1", 1_000_000),
        ("gpt-4.5", 128_000),
        ("gpt-5", 256_000),
        ("gpt-4", 8_192), // legacy GPT-4 family
        ("gpt-3.5-turbo-instruct", 4_096),
        ("gpt-3.5-turbo", 16_385),
        ("o1-preview", 128_000),
        ("o1-mini", 128_000),
        ("o1", 200_000),
        ("o3-mini", 200_000),
        ("o3", 200_000),
        ("o4-mini", 200_000),
        ("o4", 200_000),
        ("chatgpt-4o", 128_000),

        // Anthropic, if someone routes through an OpenAI-compatible proxy
        ("claude-3-5-sonnet", 200_000),
        ("claude-3-5-haiku", 200_000),
        ("claude-3-opus", 200_000),
        ("claude-3-sonnet", 200_000),
        ("claude-3-haiku", 200_000),
        ("claude-3-7", 200_000),
        ("claude-4", 200_000),
        ("claude-opus-4", 200_000),
        ("claude-sonnet-4", 1_000_000),
        ("claude-haiku-4", 200_000),
        // Broad fallback for any future Claude id not matched above. The
        // shortest prefix, so it only wins when nothing more specific does.
        ("claude", 200_000),
    ]
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// Pure functions for the hybrid-search layer: Reciprocal Rank Fusion of two
/// ranked candidate lists (vector KNN + FTS5 keyword), and FTS5 MATCH-query
/// sanitization. Kept separate from any store so they're trivially unit-tested
/// without a database or a model.
public enum HybridFusion {

    /// Reciprocal Rank Fusion. Each input list is a ranking (best-first) of
    /// chunk ids; an item's fused score is `Σ 1 / (k + rank)` across the lists
    /// it appears in (rank is 0-based). The constant `k` (default 60, the value
    /// from the original RRF paper) damps the contribution of low ranks so a
    /// single list can't dominate. Returns ids sorted by fused score, best
    /// first. The per-list input scores are intentionally ignored — RRF fuses
    /// *ranks*, which makes vector cosine and BM25 (incommensurable scales)
    /// safely combinable.
    public static func reciprocalRankFusion(
        _ rankings: [[ChunkID]],
        k: Double = 60
    ) -> [ChunkID] {
        var fused: [ChunkID: Double] = [:]
        for ranking in rankings {
            for (rank, id) in ranking.enumerated() {
                fused[id, default: 0] += 1.0 / (k + Double(rank))
            }
        }
        return fused
            .sorted { a, b in
                // Stable-ish: break score ties by chunk id so output is
                // deterministic across runs.
                a.value != b.value ? a.value > b.value : a.key.rawValue.uuidString < b.key.rawValue.uuidString
            }
            .map(\.key)
    }

    /// Turn a free-text user query into a safe FTS5 MATCH expression. FTS5
    /// treats characters like `"`, `*`, `(`, `:`, `-`, `^` as operators, so a
    /// raw user string (e.g. a code identifier `foo::bar` or a quote) can throw
    /// a syntax error. We split on whitespace, strip each token to alphanumerics
    /// (keeping unicode letters/digits), drop empties, and OR the surviving
    /// tokens as double-quoted terms. OR (not AND) maximises keyword *recall* —
    /// the reranker/RRF handles precision downstream. Returns nil if nothing
    /// usable survives (caller falls back to vector-only).
    public static func sanitizedMatchQuery(_ query: String) -> String? {
        // Split on ANY non-alphanumeric boundary into separate terms — not just
        // whitespace. This matches how FTS5's unicode61 tokenizer splits the
        // indexed text (it treats `_`, `:`, `-`, etc. as separators), so a query
        // like "FOO_BAR" becomes `"FOO" OR "BAR"` and aligns with the two tokens
        // unicode61 produced at index time. Collapsing it to one token "FOOBAR"
        // would never match.
        let tokens = query
            .unicodeScalars
            .split(whereSeparator: { !CharacterSet.alphanumerics.contains($0) })
            .map { String(String.UnicodeScalarView($0)) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        // Double-quote each term (treats it as a literal token, immune to FTS5
        // operator chars), join with OR for recall.
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}

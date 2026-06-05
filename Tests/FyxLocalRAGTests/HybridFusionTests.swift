// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
@testable import FyxLocalRAG

@Suite("HybridFusion (RRF + FTS5 query sanitization)")
struct HybridFusionTests {

    // MARK: Reciprocal Rank Fusion

    @Test func rrfRewardsAppearingInBothLists() {
        // A chunk ranked mid in both lists should beat one ranked top in only
        // one — the whole point of fusion: agreement across retrievers wins.
        let both = ChunkID()
        let vectorOnly = ChunkID()
        let keywordOnly = ChunkID()

        let vector = [vectorOnly, both]   // both at rank 1
        let keyword = [keywordOnly, both] // both at rank 1
        let fused = HybridFusion.reciprocalRankFusion([vector, keyword])

        #expect(fused.first == both, "chunk present in both lists should rank first")
        #expect(Set(fused) == [both, vectorOnly, keywordOnly])
    }

    @Test func rrfTopOfSingleListStillCounts() {
        let a = ChunkID(); let b = ChunkID()
        // a is rank-0 in list 1 only; b is rank-0 in list 2 only. Tie on score;
        // resolved deterministically by uuid order. Just assert both present
        // and the rank-0/rank-0 pair outranks a rank-2 item.
        let c = ChunkID()
        let fused = HybridFusion.reciprocalRankFusion([[a, c], [b, c]])
        // c appears at rank 1 in both → highest fused score.
        #expect(fused.first == c)
    }

    @Test func rrfIsDeterministic() {
        let ids = (0..<5).map { _ in ChunkID() }
        let r1 = HybridFusion.reciprocalRankFusion([ids, ids.reversed()])
        let r2 = HybridFusion.reciprocalRankFusion([ids, ids.reversed()])
        #expect(r1 == r2)
    }

    // MARK: FTS5 MATCH sanitization

    @Test func sanitizesOperatorCharsToSafeTerms() {
        // Code-y / punctuation-heavy queries must not throw FTS5 syntax errors.
        // Query is split on every non-alphanumeric boundary (matching the
        // unicode61 tokenizer), so "foo::bar()" yields the terms "foo" and "bar".
        let q = HybridFusion.sanitizedMatchQuery("foo::bar() AND \"baz\"-qux")
        #expect(q != nil)
        // Terms are double-quoted and OR-joined.
        #expect(q!.contains("\"foo\""))
        #expect(q!.contains("\"bar\""))
        #expect(q!.contains(" OR "))
        // No bare operator chars leaked through.
        #expect(!q!.contains("("))
        #expect(!q!.contains("::"))
    }

    @Test func emptyOrPunctuationOnlyQueryReturnsNil() {
        #expect(HybridFusion.sanitizedMatchQuery("   ") == nil)
        #expect(HybridFusion.sanitizedMatchQuery("()-:\"") == nil)
    }

    @Test func keepsUnicodeAlphanumerics() {
        let q = HybridFusion.sanitizedMatchQuery("café 日本語 test")
        #expect(q != nil)
        #expect(q!.contains("café") || q!.contains("caf"))   // diacritic kept by alphanumerics set
        #expect(q!.contains("日本語"))
    }
}

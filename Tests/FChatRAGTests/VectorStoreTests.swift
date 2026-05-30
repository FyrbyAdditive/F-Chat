// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
@testable import FChatRAG

@Suite("InMemoryVectorStore")
struct VectorStoreTests {
    @Test func upsertSearchRoundTrip() async throws {
        let store = InMemoryVectorStore(dim: 4)
        let ids = (0..<5).map { _ in ChunkID() }
        let vectors: [[Float]] = [
            [1, 0, 0, 0],
            [0.9, 0.1, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ]
        try await store.upsert(zip(ids, vectors).map { ($0.0, $0.1) })
        let hits = try await store.search(query: [1, 0, 0, 0], topK: 3)
        #expect(hits.count == 3)
        #expect(hits[0].chunkID == ids[0])
        #expect(hits[1].chunkID == ids[1])
    }

    @Test func upsertReplacesByID() async throws {
        let store = InMemoryVectorStore(dim: 4)
        let id = ChunkID()
        try await store.upsert([(id, [1, 0, 0, 0])])
        try await store.upsert([(id, [0, 1, 0, 0])])
        let count = await store.count()
        #expect(count == 1)
        let hits = try await store.search(query: [0, 1, 0, 0], topK: 1)
        #expect(hits.first?.chunkID == id)
        #expect((hits.first?.score ?? 0) > 0.99)
    }

    @Test func deleteRemovesEntry() async throws {
        let store = InMemoryVectorStore(dim: 4)
        let keep = ChunkID()
        let drop = ChunkID()
        try await store.upsert([(keep, [1, 0, 0, 0]), (drop, [0, 1, 0, 0])])
        await store.delete([drop])
        let count = await store.count()
        #expect(count == 1)
        let hits = try await store.search(query: [0, 1, 0, 0], topK: 5)
        #expect(hits.map(\.chunkID) == [keep])
    }

    @Test func dimensionMismatchThrows() async {
        let store = InMemoryVectorStore(dim: 3)
        do {
            try await store.upsert([(ChunkID(), [1, 2])])
            Issue.record("expected throw")
        } catch VectorStoreError.dimensionMismatch(let expected, let got) {
            #expect(expected == 3)
            #expect(got == 2)
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test func cosineSearchAgreesWithManualOn1kRandomCorpus() async throws {
        let dim = 32
        let store = InMemoryVectorStore(dim: dim)
        var rng = SystemRandomNumberGenerator()
        var manual: [(ChunkID, [Float])] = []
        for _ in 0..<1000 {
            let id = ChunkID()
            let vec = (0..<dim).map { _ in Float.random(in: -1...1, using: &rng) }
            manual.append((id, vec))
        }
        try await store.upsert(manual)

        let query = (0..<dim).map { _ in Float.random(in: -1...1, using: &rng) }
        let queryNorm = normalised(query)

        let manualRanking: [ChunkID] = manual
            .map { ($0.0, dot(normalised($0.1), queryNorm)) }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map { $0.0 }

        let storeHits = try await store.search(query: query, topK: 10).map(\.chunkID)
        #expect(storeHits == manualRanking)
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func normalised(_ v: [Float]) -> [Float] {
        let denom = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return denom > 0 ? v.map { $0 / denom } : v
    }
}

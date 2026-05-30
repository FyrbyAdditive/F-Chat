// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
@testable import FChatRAG

@Suite("SQLiteVecVectorStore")
struct SQLiteVecVectorStoreTests {
    private func makeStore(dim: Int = 4) throws -> (RAGDatabase, SQLiteVecVectorStore) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vec-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rag.sqlite")
        let db = try RAGDatabase(fileURL: tmp)
        let store = try SQLiteVecVectorStore(
            database: db,
            collectionID: CollectionID(),
            dim: dim,
            distance: .cosine
        )
        return (db, store)
    }

    @Test func upsertSearchRoundTrip() async throws {
        let (db, store) = try makeStore()
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
        try? FileManager.default.removeItem(at: db.fileURL.deletingLastPathComponent())
    }

    @Test func upsertReplacesByID() async throws {
        let (db, store) = try makeStore()
        let id = ChunkID()
        try await store.upsert([(id, [1, 0, 0, 0])])
        try await store.upsert([(id, [0, 1, 0, 0])])
        let count = await store.count()
        #expect(count == 1)
        let hits = try await store.search(query: [0, 1, 0, 0], topK: 1)
        #expect(hits.first?.chunkID == id)
        try? FileManager.default.removeItem(at: db.fileURL.deletingLastPathComponent())
    }

    @Test func deleteRemovesEntry() async throws {
        let (db, store) = try makeStore()
        let keep = ChunkID()
        let drop = ChunkID()
        try await store.upsert([(keep, [1, 0, 0, 0]), (drop, [0, 1, 0, 0])])
        await store.delete([drop])
        let count = await store.count()
        #expect(count == 1)
        let hits = try await store.search(query: [0, 1, 0, 0], topK: 5)
        #expect(hits.map(\.chunkID) == [keep])
        try? FileManager.default.removeItem(at: db.fileURL.deletingLastPathComponent())
    }

    @Test func dimensionMismatchThrows() async throws {
        let (db, store) = try makeStore(dim: 3)
        await #expect(throws: VectorStoreError.dimensionMismatch(expected: 3, got: 2)) {
            try await store.upsert([(ChunkID(), [1, 2])])
        }
        try? FileManager.default.removeItem(at: db.fileURL.deletingLastPathComponent())
    }

    @Test func searchRankingAgreesWithBruteForce() async throws {
        // Generate 200 random 16-dim L2-normalised vectors, store them in
        // sqlite-vec, then compare top-10 ranking against a brute-force
        // cosine ranking. With L2-normalised vectors L2 distance is
        // monotonic with negative cosine similarity, so the top-K order
        // must match exactly.
        let dim = 16
        let (db, store) = try makeStore(dim: dim)
        var rng = SystemRandomNumberGenerator()
        var corpus: [(ChunkID, [Float])] = []
        for _ in 0..<200 {
            let v = normalised((0..<dim).map { _ in Float.random(in: -1...1, using: &rng) })
            corpus.append((ChunkID(), v))
        }
        try await store.upsert(corpus)
        let q = normalised((0..<dim).map { _ in Float.random(in: -1...1, using: &rng) })

        let bruteTop = corpus
            .map { ($0.0, dot($0.1, q)) }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map(\.0)

        let vecHits = try await store.search(query: q, topK: 10).map(\.chunkID)
        #expect(vecHits == bruteTop)
        try? FileManager.default.removeItem(at: db.fileURL.deletingLastPathComponent())
    }

    @Test func vectorAsBytesPacksLittleEndianFloat32() {
        // sqlite-vec's vec_f32(?) accepts a raw little-endian float32 blob
        // of length dim*4. Verify our packed-bytes serializer produces
        // exactly that layout.
        let v: [Float] = [1.0, -2.5, 0.0, 42.125]
        let bytes = SQLiteVecVectorStore.vectorAsBytes(v)
        #expect(bytes.count == v.count * MemoryLayout<Float>.size)

        // Round-trip: re-interpret bytes as [Float] and compare exactly.
        let roundTripped: [Float] = bytes.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        #expect(roundTripped == v)
    }

    @Test func upsertSearchRoundTripsAt2560Dim() async throws {
        // Mirror of the real Qwen3 embedding dim. Catches any regression
        // in the bytes encoder at production sizes.
        let dim = 2560
        let (db, store) = try makeStore(dim: dim)
        var rng = SystemRandomNumberGenerator()
        let v = normalised((0..<dim).map { _ in Float.random(in: -1...1, using: &rng) })
        let id = ChunkID()
        try await store.upsert([(id, v)])
        let hits = try await store.search(query: v, topK: 1)
        #expect(hits.first?.chunkID == id)
        try? FileManager.default.removeItem(at: db.fileURL.deletingLastPathComponent())
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func normalised(_ v: [Float]) -> [Float] {
        let denom = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return denom > 0 ? v.map { $0 / denom } : v
    }
}

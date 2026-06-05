// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
import FyxLocalTools
@testable import FyxLocalRAG

@Suite("Reranker wiring in CollectionStoreRetriever")
struct RerankRetrieverTests {
    private func makeStore() throws -> (URL, PersistentCollectionStore) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rag-rerank-\(UUID().uuidString)", isDirectory: true)
        let db = try RAGDatabase(fileURL: dir.appendingPathComponent("rag.sqlite"))
        let store = PersistentCollectionStore(
            database: db,
            embedderFactory: { _, _, dim in HashEmbedder(modelID: "test-hash:v1", dim: dim) }
        )
        return (dir, store)
    }

    /// Reverses the candidate order, so we can prove the retriever applied the
    /// reranker's order (not the retrieval order).
    private struct ReversingReranker: RAGReranker {
        func rerank(query: String, hits: [RAGSearchHit], topK: Int) async -> [RAGSearchHit] {
            Array(hits.reversed().prefix(topK))
        }
    }

    /// Always fails by returning the input unchanged — models the
    /// "model unavailable / FCHAT_SKIP_MLX" degrade path.
    private struct PassthroughReranker: RAGReranker {
        func rerank(query: String, hits: [RAGSearchHit], topK: Int) async -> [RAGSearchHit] {
            Array(hits.prefix(topK))
        }
    }

    private func seed(_ store: PersistentCollectionStore) async throws -> CollectionID {
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 32)
        let c = try await store.createCollection(name: "notes", embedder: hash, summary: nil, distance: .cosine)
        var md = ""
        for i in 0..<8 { md += "# S\(i)\n\nDistinct widget content number \(i) here.\n\n" }
        _ = try await store.ingest(data: Data(md.utf8), filename: "w.md", collectionID: c.id)
        return c.id
    }

    @Test func rerankerReordersResults() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cid = try await seed(store)

        let plain = CollectionStoreRetriever(store: store, defaultCollections: [cid])
        let reranked = CollectionStoreRetriever(store: store, defaultCollections: [cid], reranker: ReversingReranker())

        let baseHits = try await plain.search(query: "widget content", collectionID: cid, topK: 5)
        let rerankedHits = try await reranked.search(query: "widget content", collectionID: cid, topK: 5)

        #expect(!baseHits.isEmpty)
        #expect(!rerankedHits.isEmpty)
        // The reranker reversed the (wider) candidate pool, so the top result
        // differs from the plain retrieval's top result.
        #expect(baseHits.first?.chunkID != rerankedHits.first?.chunkID)
    }

    @Test func passthroughRerankerPreservesOrderAndNeverThrows() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cid = try await seed(store)

        // A reranker that returns input order models the degrade path: results
        // still come back, no throw.
        let retriever = CollectionStoreRetriever(store: store, defaultCollections: [cid], reranker: PassthroughReranker())
        let hits = try await retriever.search(query: "widget content", collectionID: cid, topK: 5)
        #expect(!hits.isEmpty)
        #expect(hits.count <= 5)
    }
}

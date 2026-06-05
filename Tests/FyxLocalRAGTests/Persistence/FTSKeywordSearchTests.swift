// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
import FyxLocalTools
@testable import FyxLocalRAG

@Suite("FTS5 keyword + hybrid search")
struct FTSKeywordSearchTests {
    private func makeStore() throws -> (URL, PersistentCollectionStore) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rag-fts-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("rag.sqlite")
        let db = try RAGDatabase(fileURL: file)
        let store = PersistentCollectionStore(
            database: db,
            embedderFactory: { _, _, dim in HashEmbedder(modelID: "test-hash:v1", dim: dim) }
        )
        return (dir, store)
    }

    /// Ingest a body with a rare exact token and assert keyword search finds the
    /// chunk containing it. (This is the case pure-vector recall tends to miss.)
    @Test func keywordFindsExactRareTerm() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 32)
        let c = try await store.createCollection(name: "notes", embedder: hash, summary: nil, distance: .cosine)

        let body = """
        # Intro
        General prose about programming and software design principles.

        # Config
        The deployment uses the environment variable ZXQVITHRON_TOKEN to authenticate.
        """
        _ = try await store.ingest(data: Data(body.utf8), filename: "doc.md", collectionID: c.id)

        let hits = try await store.keywordSearch(query: "ZXQVITHRON_TOKEN", in: c.id, topK: 5)
        #expect(!hits.isEmpty, "keyword search should find the rare exact term")
        // The matched chunk's text contains the term.
        let chunk = await store.chunk(hits[0].chunkID)
        #expect(chunk?.text.contains("ZXQVITHRON_TOKEN") == true)
    }

    /// A query with no usable terms (or no match) returns empty, and hybrid then
    /// degrades to the pure-vector ordering rather than erroring.
    @Test func keywordEmptyDegradesHybridToVector() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 32)
        let c = try await store.createCollection(name: "notes", embedder: hash, summary: nil, distance: .cosine)
        _ = try await store.ingest(data: Data("alpha beta gamma".utf8), filename: "x.txt", collectionID: c.id)

        // Punctuation-only query → no keyword terms.
        let kw = try await store.keywordSearch(query: "()-:", in: c.id, topK: 5)
        #expect(kw.isEmpty)

        // Hybrid still returns vector results (non-empty), not an error.
        let hybrid = try await store.hybridSearch(query: "alpha", in: c.id, topK: 5)
        #expect(!hybrid.isEmpty)
    }

    /// Keyword search is scoped to its collection — a term in collection A must
    /// not surface chunks from collection B (the FTS index is global; the join
    /// must filter by collection_id).
    @Test func keywordSearchIsCollectionScoped() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 16)
        let a = try await store.createCollection(name: "A", embedder: hash, summary: nil, distance: .cosine)
        let b = try await store.createCollection(name: "B", embedder: hash, summary: nil, distance: .cosine)
        _ = try await store.ingest(data: Data("PURPLEMONKEY lives in A".utf8), filename: "a.txt", collectionID: a.id)
        _ = try await store.ingest(data: Data("nothing special in B".utf8), filename: "b.txt", collectionID: b.id)

        let inA = try await store.keywordSearch(query: "PURPLEMONKEY", in: a.id, topK: 5)
        let inB = try await store.keywordSearch(query: "PURPLEMONKEY", in: b.id, topK: 5)
        #expect(!inA.isEmpty)
        #expect(inB.isEmpty, "term from collection A must not leak into B's keyword results")
    }

    /// Deleting a document removes its chunks from the FTS index (the delete
    /// trigger fires), so its terms no longer match.
    @Test func deletingDocumentRemovesFromFTS() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 16)
        let c = try await store.createCollection(name: "notes", embedder: hash, summary: nil, distance: .cosine)
        let doc = try await store.ingest(data: Data("FINDME unique token here".utf8), filename: "d.txt", collectionID: c.id)

        #expect(!(try await store.keywordSearch(query: "FINDME", in: c.id, topK: 5)).isEmpty)
        try await store.deleteDocument(doc.id)
        #expect((try await store.keywordSearch(query: "FINDME", in: c.id, topK: 5)).isEmpty)
    }

    /// The retriever returns results bounded by topK.
    @Test func retrieverReturnsBoundedResults() async throws {
        let (dir, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 32)
        let c = try await store.createCollection(name: "notes", embedder: hash, summary: nil, distance: .cosine)
        var md = ""
        for i in 0..<6 { md += "# S\(i)\n\nDistinct content number \(i) about widgets.\n\n" }
        _ = try await store.ingest(data: Data(md.utf8), filename: "w.md", collectionID: c.id)

        let retriever = CollectionStoreRetriever(store: store, defaultCollections: [c.id])
        let hits = try await retriever.search(query: "widgets content", collectionID: c.id, topK: 4)
        #expect(!hits.isEmpty)
        #expect(hits.count <= 4)
    }
}

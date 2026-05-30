// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
@testable import FChatRAG

@Suite("PersistentCollectionStore")
struct PersistentCollectionStoreTests {
    private func makeStore() throws -> (URL, PersistentCollectionStore) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rag-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("rag.sqlite")
        let db = try RAGDatabase(fileURL: file)
        let store = PersistentCollectionStore(
            database: db,
            embedderFactory: { _, _, dim in HashEmbedder(modelID: "test-hash:v1", dim: dim) }
        )
        return (dir, store)
    }

    @Test func createListDelete() async throws {
        let (dir, store) = try makeStore()
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 16)
        let c = try await store.createCollection(name: "notes", embedder: hash, summary: nil, distance: .cosine)
        let all = await store.listCollections()
        #expect(all.map(\.name) == ["notes"])
        try await store.deleteCollection(c.id)
        #expect(await store.listCollections().isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func ingestAndSearch() async throws {
        let (dir, store) = try makeStore()
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 32)
        let c = try await store.createCollection(name: "notes", embedder: hash, summary: nil, distance: .cosine)

        let body = """
        # Swift overview
        Swift is a programming language developed by Apple.

        # Rust overview
        Rust is a systems programming language focused on safety.
        """
        _ = try await store.ingest(
            data: Data(body.utf8),
            filename: "langs.md",
            collectionID: c.id,
            ingestor: FileIngestor(),
            chunker: Chunker()
        )

        let docs = await store.documents(in: c.id)
        #expect(docs.count == 1)
        #expect(docs[0].filename == "langs.md")

        let chunks = await store.chunks(of: docs[0].id)
        #expect(chunks.count >= 2)

        let hits = try await store.search(query: "apple swift", in: c.id, topK: 3)
        #expect(!hits.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func survivesReopen() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rag-reopen-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("rag.sqlite")

        // First session: create collection + ingest a doc.
        do {
            let db = try RAGDatabase(fileURL: file)
            let store = PersistentCollectionStore(
                database: db,
                embedderFactory: { _, _, dim in HashEmbedder(modelID: "test-hash:v1", dim: dim) }
            )
            let hash = HashEmbedder(modelID: "test-hash:v1", dim: 16)
            let c = try await store.createCollection(name: "notes", embedder: hash, summary: nil, distance: .cosine)
            _ = try await store.ingest(
                data: Data("hello world".utf8),
                filename: "x.txt",
                collectionID: c.id,
                ingestor: FileIngestor(),
                chunker: Chunker()
            )
        }

        // Second session: reopen and confirm everything is there.
        let db = try RAGDatabase(fileURL: file)
        let store = PersistentCollectionStore(
            database: db,
            embedderFactory: { _, _, dim in HashEmbedder(modelID: "test-hash:v1", dim: dim) }
        )
        let collections = await store.listCollections()
        #expect(collections.count == 1)
        let docs = await store.documents(in: collections[0].id)
        #expect(docs.count == 1)
        #expect(docs[0].filename == "x.txt")
        let hits = try await store.search(query: "hello", in: collections[0].id, topK: 3)
        #expect(!hits.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func largeIngestStreamsInBatchesWithoutDroppingRows() async throws {
        // Crosses the 32-batch boundary multiple times. Catches off-by-one
        // bugs in the batching loop at edges (first batch, last batch,
        // batch boundaries) — every chunk must end up in both the chunks
        // table and the vector index.
        let (dir, store) = try makeStore()
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 16)
        let c = try await store.createCollection(name: "big", embedder: hash, summary: nil, distance: .cosine)

        // 80 markdown sections, each with a short body. The chunker emits
        // one chunk per section (each section is well under targetSize),
        // so we get ~80 chunks. That's 2 full batches of 32 plus a
        // trailing batch of 16.
        var md = ""
        for i in 0..<80 {
            md += "# Section \(i)\n\nUnique body text for section \(i) here.\n\n"
        }

        _ = try await store.ingest(
            data: Data(md.utf8),
            filename: "big.md",
            collectionID: c.id,
            ingestor: FileIngestor(),
            chunker: Chunker()
        )

        let docs = await store.documents(in: c.id)
        #expect(docs.count == 1)

        let chunks = await store.chunks(of: docs[0].id)
        #expect(chunks.count == 80, "expected 80 chunks, got \(chunks.count)")

        // Every chunk must have a vector — search hits across topK=80 with
        // a query close to one of the chunks should return that chunk.
        let hits = try await store.search(query: "Unique body text for section 42 here.", in: c.id, topK: 80)
        #expect(hits.count == 80, "vector index missing rows; got \(hits.count)")
        // First chunk's ordinal must be present (otherwise the first batch
        // somehow didn't make it into the vec table).
        let firstOrdinalIDs = chunks.filter { $0.ordinal < 32 }.map(\.id)
        let hitIDs = Set(hits.map(\.chunkID))
        for id in firstOrdinalIDs {
            #expect(hitIDs.contains(id), "first-batch chunk \(id) missing from vector index")
        }
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func surfacesParseFailureOnUnsupportedFormat() async throws {
        let (dir, store) = try makeStore()
        let hash = HashEmbedder(modelID: "test-hash:v1", dim: 16)
        let c = try await store.createCollection(name: "notes", embedder: hash, summary: nil, distance: .cosine)

        do {
            _ = try await store.ingest(
                data: Data(),
                filename: "x.docx",
                collectionID: c.id,
                ingestor: FileIngestor(),
                chunker: Chunker()
            )
            Issue.record("expected throw for unsupported .docx")
        } catch let err as PersistentIngestError {
            switch err {
            case .parseFailure(let filename, _):
                #expect(filename == "x.docx")
            }
        }

        // The document row should still exist with a parse error recorded
        // (so the UI can show it).
        let docs = await store.documents(in: c.id)
        #expect(docs.count == 1)
        try? FileManager.default.removeItem(at: dir)
    }
}

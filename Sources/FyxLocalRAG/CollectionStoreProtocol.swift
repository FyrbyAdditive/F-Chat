// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// The surface used by `CollectionStoreRetriever` and the UI for managing
/// document collections. Both `CollectionStore` (in-memory, tests/dev) and
/// `PersistentCollectionStore` (SQLite + sqlite-vec, production) conform.
public protocol CollectionStoreProtocol: Actor {
    /// All collections, in stable order. Used by the management UI's list.
    func listCollections() -> [RAGCollection]

    func collection(named name: String) -> RAGCollection?
    func collection(_ id: CollectionID) -> RAGCollection?

    /// Create a new collection wired up to the given embedder. The embedder
    /// is held for the lifetime of the store (used by ingest + search).
    @discardableResult
    func createCollection(
        name: String,
        embedder: any Embedder,
        summary: String?,
        distance: DistanceMetric
    ) async throws -> RAGCollection

    func deleteCollection(_ id: CollectionID) async throws

    /// Rename a collection. The new name must be non-empty after trimming;
    /// callers should validate before invoking. Updates `updatedAt`.
    func renameCollection(_ id: CollectionID, to newName: String) async throws

    /// All documents in a collection, oldest-first.
    func documents(in id: CollectionID) -> [RAGDocument]

    func document(_ id: DocumentID) -> RAGDocument?

    /// Chunks for a single document, ordinal-ascending.
    func chunks(of document: DocumentID) -> [RAGChunk]

    func chunk(_ id: ChunkID) -> RAGChunk?

    /// Parse + chunk + embed + persist a single document into the collection.
    @discardableResult
    func ingest(
        data: Data,
        filename: String,
        collectionID: CollectionID,
        ingestor: FileIngestor,
        chunker: Chunker
    ) async throws -> RAGDocument

    func deleteDocument(_ id: DocumentID) async throws

    /// Embed the query, run ANN, return ranked chunk ids + similarity scores.
    func search(query: String, in collectionID: CollectionID, topK: Int) async throws -> [VectorSearchHit]

    /// Keyword (BM25 / full-text) search over chunk text, ranked best-first.
    /// Returns chunk ids only (the `score` field carries BM25 rank-order, not a
    /// comparable magnitude — hybrid fusion uses ranks). Stores without a
    /// full-text index return `[]` (the default), which makes hybrid search
    /// degrade cleanly to vector-only.
    func keywordSearch(query: String, in collectionID: CollectionID, topK: Int) async throws -> [VectorSearchHit]

    /// Hybrid retrieval: vector KNN + keyword search fused with Reciprocal Rank
    /// Fusion. The default implementation runs both over a widened candidate
    /// pool and fuses; it falls back to pure vector when keyword returns nothing
    /// (or isn't supported). Returns the fused top-K chunk ids.
    func hybridSearch(query: String, in collectionID: CollectionID, topK: Int) async throws -> [VectorSearchHit]
}

public extension CollectionStoreProtocol {
    /// Default: no full-text index → no keyword hits. `PersistentCollectionStore`
    /// overrides this with an FTS5-backed implementation.
    func keywordSearch(query: String, in collectionID: CollectionID, topK: Int) async throws -> [VectorSearchHit] {
        []
    }

    /// Default hybrid: widen the candidate pool, run vector + keyword, fuse with
    /// RRF. Degrades to vector-only when keyword yields nothing. Shared by every
    /// store so the in-memory and SQLite paths behave identically (the in-memory
    /// store simply has no keyword hits, so it returns the vector order).
    func hybridSearch(query: String, in collectionID: CollectionID, topK: Int) async throws -> [VectorSearchHit] {
        // Pull a wider pool from each retriever so fusion has room to reorder.
        let poolK = max(topK * 4, topK)
        let vectorHits = (try? await search(query: query, in: collectionID, topK: poolK)) ?? []
        let keywordHits = (try? await keywordSearch(query: query, in: collectionID, topK: poolK)) ?? []

        guard !keywordHits.isEmpty else {
            // No keyword signal → plain vector order (already best-first).
            return Array(vectorHits.prefix(topK))
        }

        let fusedIDs = HybridFusion.reciprocalRankFusion([
            vectorHits.map(\.chunkID),
            keywordHits.map(\.chunkID),
        ])
        // Carry a representative score for downstream display: prefer the
        // vector cosine if the chunk had one, else the keyword rank score.
        let vectorScore = Dictionary(vectorHits.map { ($0.chunkID, $0.score) }, uniquingKeysWith: { a, _ in a })
        let keywordScore = Dictionary(keywordHits.map { ($0.chunkID, $0.score) }, uniquingKeysWith: { a, _ in a })
        return fusedIDs.prefix(topK).map { id in
            VectorSearchHit(chunkID: id, score: vectorScore[id] ?? keywordScore[id] ?? 0)
        }
    }

    func createCollection(
        name: String,
        embedder: any Embedder,
        summary: String? = nil,
        distance: DistanceMetric = .cosine
    ) async throws -> RAGCollection {
        try await createCollection(name: name, embedder: embedder, summary: summary, distance: distance)
    }

    func ingest(
        data: Data,
        filename: String,
        collectionID: CollectionID,
        ingestor: FileIngestor = FileIngestor(),
        chunker: Chunker = Chunker()
    ) async throws -> RAGDocument {
        try await ingest(data: data, filename: filename, collectionID: collectionID, ingestor: ingestor, chunker: chunker)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

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
}

public extension CollectionStoreProtocol {
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

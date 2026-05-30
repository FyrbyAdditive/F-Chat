// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import CryptoKit
import FChatCore

public actor CollectionStore: CollectionStoreProtocol {
    public private(set) var collections: [CollectionID: RAGCollection] = [:]
    public private(set) var documents: [DocumentID: RAGDocument] = [:]
    public private(set) var chunks: [ChunkID: RAGChunk] = [:]
    public private(set) var chunkContents: [ChunkID: String] = [:]
    public private(set) var collectionToDocuments: [CollectionID: [DocumentID]] = [:]
    public private(set) var documentToChunks: [DocumentID: [ChunkID]] = [:]
    public private(set) var vectorStores: [CollectionID: any VectorStore] = [:]
    public private(set) var embedders: [CollectionID: any Embedder] = [:]

    public init() {}

    public func createCollection(
        name: String,
        embedder: any Embedder,
        summary: String? = nil,
        distance: DistanceMetric = .cosine
    ) async -> RAGCollection {
        let collection = RAGCollection(
            name: name,
            summary: summary,
            embedder: embedder.kind,
            embeddingModel: embedder.modelID,
            dim: embedder.dim,
            distance: distance
        )
        collections[collection.id] = collection
        embedders[collection.id] = embedder
        vectorStores[collection.id] = InMemoryVectorStore(dim: embedder.dim, distance: distance)
        collectionToDocuments[collection.id] = []
        return collection
    }

    public func collection(named name: String) -> RAGCollection? {
        collections.values.first(where: { $0.name == name })
    }

    /// See `PersistentCollectionStore.embedBatchSize` for rationale. Keep
    /// the two stores' batching sizes identical so test/dev behaviour
    /// mirrors prod.
    private static let embedBatchSize = 16

    public func ingest(
        data: Data,
        filename: String,
        collectionID: CollectionID,
        ingestor: FileIngestor = FileIngestor(),
        chunker: Chunker = Chunker()
    ) async throws -> RAGDocument {
        guard let collection = collections[collectionID] else {
            throw IngestError.unknownCollection
        }
        guard let embedder = embedders[collectionID] else {
            throw IngestError.unknownCollection
        }
        guard let store = vectorStores[collectionID] else {
            throw IngestError.unknownCollection
        }

        let parsed = try await ingestor.parse(data: data, filename: filename)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let document = RAGDocument(
            collectionID: collectionID,
            filename: filename,
            kind: parsed.kind,
            sourcePath: nil,
            contentHash: hash,
            byteSize: data.count
        )

        var assembledChunks: [RAGChunk] = []
        var ordinal = 0
        for section in parsed.sections {
            for piece in chunker.chunk(section.text) {
                assembledChunks.append(RAGChunk(
                    documentID: document.id,
                    ordinal: ordinal,
                    text: piece,
                    meta: ChunkMeta(page: section.page, section: section.title)
                ))
                ordinal += 1
            }
        }

        guard !assembledChunks.isEmpty else {
            documents[document.id] = document
            collectionToDocuments[collectionID, default: []].append(document.id)
            documentToChunks[document.id] = []
            return document
        }

        // Stream the embed pass in fixed-size batches. Vectors land in the
        // vector store one batch at a time; the [[Float]] batch buffer is
        // dropped before the next batch starts.
        let batchSize = Self.embedBatchSize
        var index = 0
        while index < assembledChunks.count {
            let upper = min(index + batchSize, assembledChunks.count)
            let batch = assembledChunks[index..<upper]
            let texts = batch.map(\.text)
            let chunkIDs = batch.map(\.id)
            let vectors = try await embedder.embed(texts)
            precondition(vectors.count == chunkIDs.count)
            try await store.upsert(zip(chunkIDs, vectors).map { ($0, $1) })
            index = upper
        }

        documents[document.id] = document
        collectionToDocuments[collectionID, default: []].append(document.id)
        documentToChunks[document.id] = assembledChunks.map(\.id)
        for chunk in assembledChunks {
            chunks[chunk.id] = chunk
            chunkContents[chunk.id] = chunk.text
        }
        var updatedCollection = collection
        updatedCollection.updatedAt = .now
        collections[collectionID] = updatedCollection
        return document
    }

    public func search(query: String, in collectionID: CollectionID, topK: Int) async throws -> [VectorSearchHit] {
        guard let embedder = embedders[collectionID], let store = vectorStores[collectionID] else {
            throw IngestError.unknownCollection
        }
        let vector = try await embedder.embed([query])
        return try await store.search(query: vector[0], topK: topK)
    }

    public func chunk(_ id: ChunkID) -> RAGChunk? { chunks[id] }
    public func document(_ id: DocumentID) -> RAGDocument? { documents[id] }

    public func collection(_ id: CollectionID) -> RAGCollection? { collections[id] }

    public func listCollections() -> [RAGCollection] {
        collections.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func documents(in id: CollectionID) -> [RAGDocument] {
        (collectionToDocuments[id] ?? []).compactMap { documents[$0] }
    }

    public func chunks(of document: DocumentID) -> [RAGChunk] {
        (documentToChunks[document] ?? []).compactMap { chunks[$0] }.sorted { $0.ordinal < $1.ordinal }
    }

    public func deleteDocument(_ id: DocumentID) async throws {
        guard let doc = documents[id] else { return }
        if let store = vectorStores[doc.collectionID] {
            let chunkIDs = documentToChunks[id] ?? []
            await store.delete(chunkIDs)
        }
        for chunkID in (documentToChunks[id] ?? []) {
            chunks[chunkID] = nil
            chunkContents[chunkID] = nil
        }
        documentToChunks[id] = nil
        documents[id] = nil
        collectionToDocuments[doc.collectionID]?.removeAll { $0 == id }
    }

    public func deleteCollection(_ id: CollectionID) async throws {
        let docs = collectionToDocuments[id] ?? []
        for docID in docs { try await deleteDocument(docID) }
        collections[id] = nil
        collectionToDocuments[id] = nil
        vectorStores[id] = nil
        embedders[id] = nil
    }

    public func renameCollection(_ id: CollectionID, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameError.emptyName }
        guard var existing = collections[id] else { throw IngestError.unknownCollection }
        existing.name = trimmed
        existing.updatedAt = .now
        collections[id] = existing
    }
}

public enum RenameError: Error, Sendable, Equatable {
    case emptyName
}

public enum IngestError: Error, Sendable, Equatable {
    case unknownCollection
}

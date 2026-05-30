// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import CryptoKit
import GRDB
import FChatCore

/// Production-grade `CollectionStoreProtocol` impl backed by SQLite +
/// sqlite-vec for the vector indices.
///
/// Collections, documents, chunks live in the SQL schema defined by
/// `RAGDatabase`. Per-collection vector tables are managed by
/// `SQLiteVecVectorStore`. Embedders and live vector stores are kept in
/// memory keyed by collection id — `embedderFactory` rebuilds an embedder
/// on first reference after a fresh app launch.
public actor PersistentCollectionStore: CollectionStoreProtocol {
    public let database: RAGDatabase
    private var embedders: [CollectionID: any Embedder] = [:]
    private var vectorStores: [CollectionID: SQLiteVecVectorStore] = [:]
    /// Recreates an embedder instance from the persisted (kind, model, dim)
    /// after a fresh app launch (when the in-memory dictionary is empty).
    public let embedderFactory: @Sendable (EmbedderKind, String, Int) async throws -> any Embedder

    public init(
        database: RAGDatabase,
        embedderFactory: @escaping @Sendable (EmbedderKind, String, Int) async throws -> any Embedder
    ) {
        self.database = database
        self.embedderFactory = embedderFactory
    }

    // MARK: - Collections

    public func listCollections() -> [RAGCollection] {
        (try? database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, summary, embedder_kind, embedding_model, dim, distance, created_at, updated_at
                FROM collections ORDER BY created_at ASC
                """).compactMap { row in Self.decodeCollection(row) }
        }) ?? []
    }

    public func collection(named name: String) -> RAGCollection? {
        (try? database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, name, summary, embedder_kind, embedding_model, dim, distance, created_at, updated_at
                FROM collections WHERE name = ? LIMIT 1
                """, arguments: [name]).flatMap { Self.decodeCollection($0) }
        }) ?? nil
    }

    public func collection(_ id: CollectionID) -> RAGCollection? {
        (try? database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, name, summary, embedder_kind, embedding_model, dim, distance, created_at, updated_at
                FROM collections WHERE id = ? LIMIT 1
                """, arguments: [id.rawValue.uuidString]).flatMap { Self.decodeCollection($0) }
        }) ?? nil
    }

    public func createCollection(
        name: String,
        embedder: any Embedder,
        summary: String?,
        distance: DistanceMetric
    ) async throws -> RAGCollection {
        let collection = RAGCollection(
            name: name,
            summary: summary,
            embedder: embedder.kind,
            embeddingModel: embedder.modelID,
            dim: embedder.dim,
            distance: distance
        )
        try await database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO collections(id, name, summary, embedder_kind, embedding_model, dim, distance, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    collection.id.rawValue.uuidString,
                    collection.name,
                    collection.summary,
                    collection.embedder.rawValue,
                    collection.embeddingModel,
                    collection.dim,
                    collection.distance.rawValue,
                    collection.createdAt.timeIntervalSince1970,
                    collection.updatedAt.timeIntervalSince1970,
                ])
        }
        let store = try SQLiteVecVectorStore(
            database: database,
            collectionID: collection.id,
            dim: embedder.dim,
            distance: distance
        )
        embedders[collection.id] = embedder
        vectorStores[collection.id] = store
        return collection
    }

    public func deleteCollection(_ id: CollectionID) async throws {
        // Drop the vec0 table first (CASCADE handles documents+chunks but
        // not the per-collection virtual table since it isn't a FK target).
        if let store = vectorStores[id] {
            try await store.drop()
        }
        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [id.rawValue.uuidString])
        }
        embedders[id] = nil
        vectorStores[id] = nil
    }

    public func renameCollection(_ id: CollectionID, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameError.emptyName }
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE collections SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, Date.now.timeIntervalSince1970, id.rawValue.uuidString]
            )
        }
    }

    // MARK: - Documents / chunks

    public func documents(in id: CollectionID) -> [RAGDocument] {
        (try? database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, collection_id, filename, kind, source_path, content_hash, ingested_at, byte_size
                FROM documents WHERE collection_id = ? ORDER BY ingested_at ASC
                """, arguments: [id.rawValue.uuidString]).compactMap { Self.decodeDocument($0) }
        }) ?? []
    }

    public func document(_ id: DocumentID) -> RAGDocument? {
        (try? database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, collection_id, filename, kind, source_path, content_hash, ingested_at, byte_size
                FROM documents WHERE id = ? LIMIT 1
                """, arguments: [id.rawValue.uuidString]).flatMap { Self.decodeDocument($0) }
        }) ?? nil
    }

    public func chunks(of document: DocumentID) -> [RAGChunk] {
        (try? database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, document_id, ordinal, text, page, section, language, token_count
                FROM chunks WHERE document_id = ? ORDER BY ordinal ASC
                """, arguments: [document.rawValue.uuidString]).compactMap { Self.decodeChunk($0) }
        }) ?? []
    }

    public func chunk(_ id: ChunkID) -> RAGChunk? {
        (try? database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, document_id, ordinal, text, page, section, language, token_count
                FROM chunks WHERE id = ? LIMIT 1
                """, arguments: [id.rawValue.uuidString]).flatMap { Self.decodeChunk($0) }
        }) ?? nil
    }

    /// How many chunks we send to the embedder per forward pass. Set to keep
    /// peak GPU memory bounded regardless of the document size — a book that
    /// chunks into 10k pieces is processed as ~625 batches of 16 rather than
    /// one giant tensor. Combined with MLXQwen3Embedder's per-batch
    /// `clearCache()` call and per-chunk sequence-length cap, this keeps
    /// peak memory roughly constant across the run. Tuned by hand against
    /// MLXQwen3Embedder; revisit if we add larger or smaller embedders.
    private static let embedBatchSize = 16

    public func ingest(
        data: Data,
        filename: String,
        collectionID: CollectionID,
        ingestor: FileIngestor,
        chunker: Chunker
    ) async throws -> RAGDocument {
        guard let collection = collection(collectionID) else { throw IngestError.unknownCollection }
        let embedder = try await embedderForCollection(collection)
        let store = try vectorStoreForCollection(collection)

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        var parseError: String?
        var parsed: ParsedDocument?
        do {
            parsed = try await ingestor.parse(data: data, filename: filename)
        } catch let err as DocumentParserError {
            parseError = String(describing: err)
        } catch {
            parseError = error.localizedDescription
        }

        let document = RAGDocument(
            collectionID: collectionID,
            filename: filename,
            kind: parsed?.kind ?? .text,
            sourcePath: nil,
            contentHash: hash,
            byteSize: data.count
        )

        // Build the chunk list once. The chunk text already lives inside
        // each `RAGChunk` (no separate `[String]` mirror), so we don't pay
        // the string overhead twice.
        var allChunks: [RAGChunk] = []
        if let parsed {
            var ordinal = 0
            for section in parsed.sections {
                for piece in chunker.chunk(section.text) {
                    allChunks.append(RAGChunk(
                        documentID: document.id,
                        ordinal: ordinal,
                        text: piece,
                        meta: ChunkMeta(page: section.page, section: section.title)
                    ))
                    ordinal += 1
                }
            }
        }

        let chunksSnapshot = allChunks
        let documentSnapshot = document
        let parseErrorSnapshot = parseError
        try await database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO documents(id, collection_id, filename, kind, source_path, content_hash, ingested_at, byte_size, parse_error, chunk_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    documentSnapshot.id.rawValue.uuidString,
                    documentSnapshot.collectionID.rawValue.uuidString,
                    documentSnapshot.filename,
                    documentSnapshot.kind.rawValue,
                    documentSnapshot.sourcePath,
                    documentSnapshot.contentHash,
                    documentSnapshot.ingestedAt.timeIntervalSince1970,
                    documentSnapshot.byteSize,
                    parseErrorSnapshot,
                    chunksSnapshot.count,
                ])
            for chunk in chunksSnapshot {
                try db.execute(sql: """
                    INSERT INTO chunks(id, document_id, ordinal, text, page, section, language, token_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        chunk.id.rawValue.uuidString,
                        chunk.documentID.rawValue.uuidString,
                        chunk.ordinal,
                        chunk.text,
                        chunk.meta.page,
                        chunk.meta.section,
                        chunk.meta.language,
                        chunk.meta.tokenCount,
                    ])
            }
        }

        // Now stream the embed step in fixed-size batches and upsert each
        // batch's vectors immediately. ARC drops batch-scoped [[Float]]
        // before the next batch starts, so peak memory is
        // O(batch_size * dim * 4 bytes) regardless of the document size.
        if !allChunks.isEmpty {
            let batchSize = Self.embedBatchSize
            var index = 0
            while index < allChunks.count {
                let upper = min(index + batchSize, allChunks.count)
                let batch = allChunks[index..<upper]
                let texts = batch.map(\.text)
                let chunkIDs = batch.map(\.id)
                let vectors = try await embedder.embed(texts)
                precondition(vectors.count == chunkIDs.count)
                try await store.upsert(zip(chunkIDs, vectors).map { ($0, $1) })
                index = upper
            }
        }

        try await touchCollection(collectionID)

        if let parseError {
            // We persisted the doc with the error so the UI can show it,
            // but raise so the ingest queue can surface a failure status too.
            throw PersistentIngestError.parseFailure(filename: filename, message: parseError)
        }
        return document
    }

    public func deleteDocument(_ id: DocumentID) async throws {
        guard let doc = document(id) else { return }
        if let store = vectorStores[doc.collectionID] {
            let chunkIDs = chunks(of: id).map(\.id)
            await store.delete(chunkIDs)
        }
        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id.rawValue.uuidString])
        }
    }

    public func search(query: String, in collectionID: CollectionID, topK: Int) async throws -> [VectorSearchHit] {
        guard let collection = collection(collectionID) else { throw IngestError.unknownCollection }
        let embedder = try await embedderForCollection(collection)
        let store = try vectorStoreForCollection(collection)
        let vectors = try await embedder.embed([query])
        return try await store.search(query: vectors[0], topK: topK)
    }

    // MARK: - Lazy embedders / stores

    private func embedderForCollection(_ collection: RAGCollection) async throws -> any Embedder {
        if let cached = embedders[collection.id] { return cached }
        let fresh = try await embedderFactory(collection.embedder, collection.embeddingModel, collection.dim)
        embedders[collection.id] = fresh
        return fresh
    }

    private func vectorStoreForCollection(_ collection: RAGCollection) throws -> SQLiteVecVectorStore {
        if let cached = vectorStores[collection.id] { return cached }
        let fresh = try SQLiteVecVectorStore(
            database: database,
            collectionID: collection.id,
            dim: collection.dim,
            distance: collection.distance
        )
        vectorStores[collection.id] = fresh
        return fresh
    }

    private func touchCollection(_ id: CollectionID) async throws {
        try await database.queue.write { db in
            try db.execute(sql: "UPDATE collections SET updated_at = ? WHERE id = ?",
                           arguments: [Date.now.timeIntervalSince1970, id.rawValue.uuidString])
        }
    }

    // MARK: - Row decoders

    static func decodeCollection(_ row: Row) -> RAGCollection? {
        guard
            let idStr: String = row["id"], let uuid = UUID(uuidString: idStr),
            let name: String = row["name"],
            let kindRaw: String = row["embedder_kind"], let kind = EmbedderKind(rawValue: kindRaw),
            let model: String = row["embedding_model"],
            let dim: Int = row["dim"],
            let distRaw: String = row["distance"], let distance = DistanceMetric(rawValue: distRaw),
            let createdAt: Double = row["created_at"],
            let updatedAt: Double = row["updated_at"]
        else { return nil }
        return RAGCollection(
            id: CollectionID(rawValue: uuid),
            name: name,
            summary: row["summary"],
            embedder: kind,
            embeddingModel: model,
            dim: dim,
            distance: distance,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    static func decodeDocument(_ row: Row) -> RAGDocument? {
        guard
            let idStr: String = row["id"], let uuid = UUID(uuidString: idStr),
            let collStr: String = row["collection_id"], let collUUID = UUID(uuidString: collStr),
            let filename: String = row["filename"],
            let kindRaw: String = row["kind"], let kind = DocumentKind(rawValue: kindRaw),
            let hash: String = row["content_hash"],
            let ingestedAt: Double = row["ingested_at"],
            let byteSize: Int = row["byte_size"]
        else { return nil }
        return RAGDocument(
            id: DocumentID(rawValue: uuid),
            collectionID: CollectionID(rawValue: collUUID),
            filename: filename,
            kind: kind,
            sourcePath: row["source_path"],
            contentHash: hash,
            ingestedAt: Date(timeIntervalSince1970: ingestedAt),
            byteSize: byteSize
        )
    }

    static func decodeChunk(_ row: Row) -> RAGChunk? {
        guard
            let idStr: String = row["id"], let uuid = UUID(uuidString: idStr),
            let docStr: String = row["document_id"], let docUUID = UUID(uuidString: docStr),
            let ordinal: Int = row["ordinal"],
            let text: String = row["text"]
        else { return nil }
        return RAGChunk(
            id: ChunkID(rawValue: uuid),
            documentID: DocumentID(rawValue: docUUID),
            ordinal: ordinal,
            text: text,
            meta: ChunkMeta(
                page: row["page"],
                section: row["section"],
                language: row["language"],
                tokenCount: row["token_count"]
            )
        )
    }
}

public enum PersistentIngestError: Error, Sendable, Equatable {
    case parseFailure(filename: String, message: String)
}

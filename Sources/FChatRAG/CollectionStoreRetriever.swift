// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatTools

/// Adapts a `CollectionStoreProtocol` to the Tools-layer `RAGRetriever`
/// protocol so the built-in `rag_search` tool can drive whichever store
/// (in-memory or SQLite-backed) the app happens to have configured.
public struct CollectionStoreRetriever: RAGRetriever {
    public let store: any CollectionStoreProtocol
    /// Default collections to search when the model doesn't pass a name.
    /// `ChatViewModel` sets this from `Conversation.settings.attachedCollections`
    /// before invoking the tool.
    public let defaultCollections: [CollectionID]

    public init(store: any CollectionStoreProtocol, defaultCollections: [CollectionID] = []) {
        self.store = store
        self.defaultCollections = defaultCollections
    }

    public func search(query: String, collectionID: CollectionID, topK: Int) async throws -> [RAGSearchHit] {
        let hits = try await store.search(query: query, in: collectionID, topK: topK)
        return await materialise(hits: hits)
    }

    /// Search every attached collection and merge the top-k. Used when the
    /// model omits the `collection` argument (which it routinely does even
    /// when told not to).
    public func searchAll(query: String, topK: Int) async throws -> [RAGSearchHit] {
        guard !defaultCollections.isEmpty else { return [] }
        var combined: [VectorSearchHit] = []
        for cid in defaultCollections {
            do {
                let hits = try await store.search(query: query, in: cid, topK: topK)
                combined.append(contentsOf: hits)
            } catch {
                // Continue with the other collections on per-collection failure.
                continue
            }
        }
        combined.sort { $0.score > $1.score }
        let trimmed = Array(combined.prefix(topK))
        return await materialise(hits: trimmed)
    }

    public func collection(named name: String) async throws -> CollectionID? {
        await store.collection(named: name)?.id
    }

    private func materialise(hits: [VectorSearchHit]) async -> [RAGSearchHit] {
        var output: [RAGSearchHit] = []
        for hit in hits {
            guard let chunk = await store.chunk(hit.chunkID) else { continue }
            let document = await store.document(chunk.documentID)
            output.append(RAGSearchHit(
                chunkID: hit.chunkID,
                documentName: document?.filename ?? "unknown",
                page: chunk.meta.page,
                section: chunk.meta.section,
                text: chunk.text,
                score: Double(hit.score)
            ))
        }
        return output
    }
}

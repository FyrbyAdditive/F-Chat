// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import FyxLocalTools

/// Adapts a `CollectionStoreProtocol` to the Tools-layer `RAGRetriever`
/// protocol so the built-in `rag_search` tool can drive whichever store
/// (in-memory or SQLite-backed) the app happens to have configured.
public struct CollectionStoreRetriever: RAGRetriever {
    public let store: any CollectionStoreProtocol
    /// Default collections to search when the model doesn't pass a name.
    /// `ChatViewModel` sets this from `Conversation.settings.attachedCollections`
    /// before invoking the tool.
    public let defaultCollections: [CollectionID]
    /// Optional cross-encoder rerank stage applied after hybrid retrieval.
    /// Injected from the app (the MLX-backed reranker). `nil` → no rerank.
    public let reranker: (any RAGReranker)?
    /// Whether to run hybrid (keyword+vector) retrieval. When false, falls back
    /// to pure vector. Surfaced as a user setting; defaults to on.
    public let useHybrid: Bool

    public init(
        store: any CollectionStoreProtocol,
        defaultCollections: [CollectionID] = [],
        reranker: (any RAGReranker)? = nil,
        useHybrid: Bool = true
    ) {
        self.store = store
        self.defaultCollections = defaultCollections
        self.reranker = reranker
        self.useHybrid = useHybrid
    }

    /// Retrieve from one collection. To give the reranker room to reorder, we
    /// pull a wider candidate pool than `topK`, rerank, then truncate.
    public func search(query: String, collectionID: CollectionID, topK: Int) async throws -> [RAGSearchHit] {
        let poolK = candidatePool(for: topK)
        let raw = try await retrieve(query: query, collectionID: collectionID, topK: poolK)
        let materialised = await materialise(hits: raw)
        return await applyRerank(query: query, hits: materialised, topK: topK)
    }

    /// Search every attached collection, merge, rerank. Used when the model
    /// omits the `collection` argument (which it routinely does even when
    /// told not to).
    public func searchAll(query: String, topK: Int) async throws -> [RAGSearchHit] {
        guard !defaultCollections.isEmpty else { return [] }
        let poolK = candidatePool(for: topK)
        var combined: [VectorSearchHit] = []
        for cid in defaultCollections {
            do {
                let hits = try await retrieve(query: query, collectionID: cid, topK: poolK)
                combined.append(contentsOf: hits)
            } catch {
                // Continue with the other collections on per-collection failure.
                continue
            }
        }
        combined.sort { $0.score > $1.score }
        let materialised = await materialise(hits: Array(combined.prefix(poolK)))
        return await applyRerank(query: query, hits: materialised, topK: topK)
    }

    public func collection(named name: String) async throws -> CollectionID? {
        await store.collection(named: name)?.id
    }

    // MARK: - Pipeline stages

    /// Widen the candidate pool when a reranker is present (it needs more than
    /// `topK` to meaningfully reorder); otherwise the retriever's own order is
    /// final, so don't over-fetch.
    private func candidatePool(for topK: Int) -> Int {
        reranker == nil ? topK : max(topK * 4, topK)
    }

    /// One collection's raw hits — hybrid when enabled, else pure vector.
    private func retrieve(query: String, collectionID: CollectionID, topK: Int) async throws -> [VectorSearchHit] {
        if useHybrid {
            return try await store.hybridSearch(query: query, in: collectionID, topK: topK)
        }
        return try await store.search(query: query, in: collectionID, topK: topK)
    }

    /// Apply the reranker if present; it degrades to input order internally on
    /// failure, so this never throws. Truncates to `topK` either way.
    private func applyRerank(query: String, hits: [RAGSearchHit], topK: Int) async -> [RAGSearchHit] {
        guard let reranker else { return Array(hits.prefix(topK)) }
        return await reranker.rerank(query: query, hits: hits, topK: topK)
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

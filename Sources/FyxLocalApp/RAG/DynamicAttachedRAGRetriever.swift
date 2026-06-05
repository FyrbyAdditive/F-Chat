// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import FyxLocalTools
import FyxLocalRAG

/// Adapts a `CollectionStoreProtocol` to the Tools-layer `RAGRetriever`
/// protocol with one twist: the set of "attached" collections (used when
/// the model omits the `collection` argument) is fetched lazily through
/// a `@MainActor`-bound closure that reads the active chat's settings.
///
/// We can't bake the attached set into the retriever at registration
/// time because the active chat changes; a closure lets a single
/// long-lived tool instance route to the right collections per turn.
struct DynamicAttachedRAGRetriever: RAGRetriever {
    let store: any CollectionStoreProtocol
    let attachedAccessor: @Sendable @MainActor () -> [CollectionID]
    /// Per-turn retrieval settings, read live so the Settings toggle takes
    /// effect on the next search without rebuilding the tool. `reranker` is the
    /// on-device cross-encoder (nil until loaded / when disabled); `useHybrid`
    /// gates keyword+vector fusion vs pure vector.
    var settingsAccessor: (@Sendable @MainActor () -> RAGRetrievalSettings)? = nil

    func search(query: String, collectionID: CollectionID, topK: Int) async throws -> [RAGSearchHit] {
        let settings = await resolveSettings()
        return try await delegate(attached: [], settings: settings).search(query: query, collectionID: collectionID, topK: topK)
    }

    func collection(named name: String) async throws -> CollectionID? {
        try await delegate(attached: [], settings: .init()).collection(named: name)
    }

    func searchAll(query: String, topK: Int) async throws -> [RAGSearchHit] {
        let attached = await MainActor.run { attachedAccessor() }
        let settings = await resolveSettings()
        return try await delegate(attached: attached, settings: settings).searchAll(query: query, topK: topK)
    }

    private func resolveSettings() async -> RAGRetrievalSettings {
        guard let settingsAccessor else { return .init() }
        return await MainActor.run { settingsAccessor() }
    }

    private func delegate(attached: [CollectionID], settings: RAGRetrievalSettings) -> CollectionStoreRetriever {
        CollectionStoreRetriever(
            store: store,
            defaultCollections: attached,
            reranker: settings.reranker,
            useHybrid: settings.useHybrid
        )
    }
}

/// Live retrieval settings snapshot read per turn.
struct RAGRetrievalSettings {
    var useHybrid: Bool = true
    var reranker: (any RAGReranker)? = nil
}

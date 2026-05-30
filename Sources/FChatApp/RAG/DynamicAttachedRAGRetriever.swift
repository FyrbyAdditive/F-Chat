// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatTools
import FChatRAG

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

    func search(query: String, collectionID: CollectionID, topK: Int) async throws -> [RAGSearchHit] {
        try await delegate(attached: []).search(query: query, collectionID: collectionID, topK: topK)
    }

    func collection(named name: String) async throws -> CollectionID? {
        try await delegate(attached: []).collection(named: name)
    }

    func searchAll(query: String, topK: Int) async throws -> [RAGSearchHit] {
        let attached = await MainActor.run { attachedAccessor() }
        return try await delegate(attached: attached).searchAll(query: query, topK: topK)
    }

    private func delegate(attached: [CollectionID]) -> CollectionStoreRetriever {
        CollectionStoreRetriever(store: store, defaultCollections: attached)
    }
}

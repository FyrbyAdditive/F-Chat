// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatRAG
import FChatTools
@testable import FChatApp

/// Proves that the DynamicAttachedRAGRetriever — which is the bridge between
/// `RAGSearchTool` and the per-chat attached-collections set — picks up the
/// value from `ChatTaskContext` instead of any shared mutable field. This
/// guarantees two concurrent chat streams can each call rag_search and see
/// only their own attached collections.
@Suite("DynamicAttachedRAGRetriever")
struct DynamicAttachedRAGRetrieverTests {
    @Test func searchAllRespectsTheTaskLocalAttachedSet() async throws {
        let store = CollectionStore()
        let aEmbedder = HashEmbedder(modelID: "test:a", dim: 16)
        let bEmbedder = HashEmbedder(modelID: "test:b", dim: 16)
        let a = try await store.createCollection(name: "alpha", embedder: aEmbedder)
        let b = try await store.createCollection(name: "beta", embedder: bEmbedder)
        _ = try await store.ingest(
            data: Data("alpha unique content here".utf8),
            filename: "alpha.txt",
            collectionID: a.id
        )
        _ = try await store.ingest(
            data: Data("beta unique content here".utf8),
            filename: "beta.txt",
            collectionID: b.id
        )

        // The retriever uses the same TaskLocal AppEnvironment hooks up to
        // its accessor at registration. Verify scoped reads.
        let retriever = DynamicAttachedRAGRetriever(
            store: store,
            attachedAccessor: { ChatTaskContext.attachedCollections }
        )

        // With only A in scope, searchAll must only hit A's data.
        let hitsA = await ChatTaskContext.$attachedCollections.withValue([a.id]) {
            (try? await retriever.searchAll(query: "alpha", topK: 5)) ?? []
        }
        #expect(!hitsA.isEmpty)
        for hit in hitsA {
            #expect(hit.documentName == "alpha.txt")
        }

        // With B in scope, the same query should only return B's chunks.
        let hitsB = await ChatTaskContext.$attachedCollections.withValue([b.id]) {
            (try? await retriever.searchAll(query: "beta", topK: 5)) ?? []
        }
        #expect(!hitsB.isEmpty)
        for hit in hitsB {
            #expect(hit.documentName == "beta.txt")
        }

        // With no scope set, searchAll should return nothing — the
        // retriever's default (no attached set, no implicit collection).
        let hitsNone = (try? await retriever.searchAll(query: "alpha", topK: 5)) ?? []
        #expect(hitsNone.isEmpty)
    }
}

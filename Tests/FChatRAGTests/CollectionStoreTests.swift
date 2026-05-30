// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatTools
@testable import FChatRAG

@Suite("CollectionStore")
struct CollectionStoreTests {
    @Test func ingestAndSearchEndToEnd() async throws {
        let store = CollectionStore()
        let embedder = HashEmbedder(dim: 32)
        let collection = await store.createCollection(name: "notes", embedder: embedder)

        let body = """
        # Swift overview
        Swift is a programming language developed by Apple.

        # Rust overview
        Rust is a systems programming language focused on safety.
        """
        _ = try await store.ingest(data: Data(body.utf8), filename: "langs.md", collectionID: collection.id)

        let swiftHits = try await store.search(query: "apple swift", in: collection.id, topK: 3)
        #expect(!swiftHits.isEmpty)

        let chunk = await store.chunk(swiftHits[0].chunkID)
        #expect(chunk?.text.lowercased().contains("swift") == true)
    }

    @Test func retrieverAdapterExposesHitsToToolsLayer() async throws {
        let store = CollectionStore()
        let embedder = HashEmbedder(dim: 32)
        let collection = await store.createCollection(name: "notes", embedder: embedder)
        let text = "Liquid Glass is a macOS 26 UI material."
        _ = try await store.ingest(data: Data(text.utf8), filename: "liquid.md", collectionID: collection.id)

        let retriever = CollectionStoreRetriever(store: store)
        let resolved = try await retriever.collection(named: "notes")
        #expect(resolved == collection.id)
        let hits = try await retriever.search(query: "liquid glass macOS", collectionID: collection.id, topK: 5)
        #expect(!hits.isEmpty)
        #expect(hits[0].documentName == "liquid.md")
    }
}

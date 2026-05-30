// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
@testable import FChatTools

@Suite("RAGSearchTool")
struct RAGSearchToolTests {
    @Test func happyPath() async throws {
        let collection = CollectionID()
        let retriever = StubRetriever(
            collectionByName: ["notes": collection],
            hits: [
                RAGSearchHit(chunkID: .init(), documentName: "spec.md", page: nil, section: "Intro", text: "Foo bar baz", score: 0.91)
            ]
        )
        let tool = RAGSearchTool(retriever: retriever)
        let output = try await tool.invoke(arguments: #"{"query":"baz","collection":"notes","top_k":3}"#)
        #expect(output.outputJSON.contains("spec.md"))
        #expect(output.outputJSON.contains("0.91"))
    }

    @Test func unknownCollectionReturnsErrorOutput() async throws {
        let tool = RAGSearchTool(retriever: StubRetriever(collectionByName: [:], hits: []))
        let output = try await tool.invoke(arguments: #"{"query":"x","collection":"missing"}"#)
        #expect(output.isError == true)
        #expect(output.outputJSON.contains("unknown collection"))
    }
}

actor StubRetriever: RAGRetriever {
    let collectionByName: [String: CollectionID]
    let hits: [RAGSearchHit]
    init(collectionByName: [String: CollectionID], hits: [RAGSearchHit]) {
        self.collectionByName = collectionByName
        self.hits = hits
    }
    func search(query: String, collectionID: CollectionID, topK: Int) async throws -> [RAGSearchHit] {
        hits
    }
    func collection(named name: String) async throws -> CollectionID? {
        collectionByName[name]
    }
}

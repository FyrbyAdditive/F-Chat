// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import FyxLocalProviders

public protocol RAGRetriever: Sendable {
    func search(query: String, collectionID: CollectionID, topK: Int) async throws -> [RAGSearchHit]
    func collection(named name: String) async throws -> CollectionID?
    /// Search across every collection the current chat has attached.
    /// Used when the model omits the `collection` argument — which it
    /// routinely does even when told not to.
    func searchAll(query: String, topK: Int) async throws -> [RAGSearchHit]
}

public extension RAGRetriever {
    func searchAll(query: String, topK: Int) async throws -> [RAGSearchHit] {
        []
    }
}

public struct RAGSearchHit: Sendable, Hashable, Codable {
    public var chunkID: ChunkID
    public var documentName: String
    public var page: Int?
    public var section: String?
    public var text: String
    public var score: Double

    public init(chunkID: ChunkID, documentName: String, page: Int?, section: String?, text: String, score: Double) {
        self.chunkID = chunkID
        self.documentName = documentName
        self.page = page
        self.section = section
        self.text = text
        self.score = score
    }
}

/// Re-orders candidate hits by relevance to the query (a cross-encoder pass).
/// Lives in the Tools layer so `CollectionStoreRetriever` can hold one without
/// depending on the MLX layer directly; the concrete MLX implementation is
/// injected from the app. Implementations MUST degrade gracefully — on any
/// failure they should return the input order rather than throw, so rag_search
/// never errors just because the reranker is unavailable.
public protocol RAGReranker: Sendable {
    /// Return `hits` re-ordered best-first for `query`, truncated to `topK`.
    func rerank(query: String, hits: [RAGSearchHit], topK: Int) async -> [RAGSearchHit]
}

public struct RAGSearchTool: Tool {
    public let name = "rag_search"
    public let retriever: any RAGRetriever
    public let defaultTopK: Int

    public init(retriever: any RAGRetriever, defaultTopK: Int = 6) {
        self.retriever = retriever
        self.defaultTopK = defaultTopK
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description = PromptStrings.string("tool.rag_search.desc", language)
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"query":{"type":"string"},"collection":{"type":"string","description":"Optional collection name. Omit to search every collection attached to this chat."},"top_k":{"type":"integer","minimum":1,"maximum":20,"default":6}},"required":["query"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: false)
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        struct Args: Decodable {
            let query: String
            let collection: String?
            let top_k: Int?
        }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.isEmpty ? "{}" : trimmed
        guard let data = normalised.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Args.self, from: data) else {
            let body = #"{"error":"Could not parse arguments. Expected {\"query\": string, \"collection\"?: string}."}"#
            return ToolOutput(outputJSON: body, isError: true, display: .markdown)
        }
        let cleanQuery = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else {
            return ToolOutput(outputJSON: #"{"error":"query is empty"}"#, isError: true, display: .markdown)
        }
        let topK = max(1, min(parsed.top_k ?? defaultTopK, 20))

        let collectionLabel: String
        let hits: [RAGSearchHit]
        if let name = parsed.collection?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            guard let id = try await retriever.collection(named: name) else {
                let body = #"{"error":"unknown collection '\#(name.escapedForJSONInline())'"}"#
                return ToolOutput(outputJSON: body, isError: true, display: .markdown)
            }
            collectionLabel = name
            hits = try await retriever.search(query: cleanQuery, collectionID: id, topK: topK)
        } else {
            collectionLabel = "(all attached)"
            hits = try await retriever.searchAll(query: cleanQuery, topK: topK)
        }
        let payload = RAGSearchPayload(query: cleanQuery, collection: collectionLabel, hits: hits)
        let json = try JSONEncoder().encode(payload)
        return ToolOutput(outputJSON: String(data: json, encoding: .utf8) ?? "{}", display: .markdown)
    }
}

private struct RAGSearchPayload: Encodable {
    let query: String
    let collection: String
    let hits: [RAGSearchHit]
}

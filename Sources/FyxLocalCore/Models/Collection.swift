// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public struct RAGCollection: Identifiable, Sendable, Hashable, Codable {
    public let id: CollectionID
    public var name: String
    public var summary: String?
    public var embedder: EmbedderKind
    public var embeddingModel: String
    public var dim: Int
    public var distance: DistanceMetric
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: CollectionID = .init(),
        name: String,
        summary: String? = nil,
        embedder: EmbedderKind,
        embeddingModel: String,
        dim: Int,
        distance: DistanceMetric = .cosine,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.embedder = embedder
        self.embeddingModel = embeddingModel
        self.dim = dim
        self.distance = distance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum EmbedderKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// On-device embeddings via MLX running Qwen3-Embedding-4B on the
    /// Apple Silicon GPU. 2560-dim vectors, ~5ms per chunk on M-series.
    case mlxQwen3Embedding4B
    /// Remote embeddings from an OpenAI-compatible /embeddings endpoint.
    case openAICompatible
    /// Test/dev only: HashEmbedder produces deterministic vectors
    /// without any model. Never used in production.
    case test
}

public enum DistanceMetric: String, Sendable, Hashable, Codable, CaseIterable {
    case cosine, l2, dot
}

public struct RAGDocument: Identifiable, Sendable, Hashable, Codable {
    public let id: DocumentID
    public var collectionID: CollectionID
    public var filename: String
    public var kind: DocumentKind
    public var sourcePath: String?
    public var contentHash: String
    public var ingestedAt: Date
    public var byteSize: Int

    public init(
        id: DocumentID = .init(),
        collectionID: CollectionID,
        filename: String,
        kind: DocumentKind,
        sourcePath: String? = nil,
        contentHash: String,
        ingestedAt: Date = .now,
        byteSize: Int
    ) {
        self.id = id
        self.collectionID = collectionID
        self.filename = filename
        self.kind = kind
        self.sourcePath = sourcePath
        self.contentHash = contentHash
        self.ingestedAt = ingestedAt
        self.byteSize = byteSize
    }
}

public enum DocumentKind: String, Sendable, Hashable, Codable, CaseIterable {
    case pdf, text, markdown, docx, pptx, code, html, jupyter, rtf
}

public struct RAGChunk: Identifiable, Sendable, Hashable, Codable {
    public let id: ChunkID
    public var documentID: DocumentID
    public var ordinal: Int
    public var text: String
    public var meta: ChunkMeta

    public init(
        id: ChunkID = .init(),
        documentID: DocumentID,
        ordinal: Int,
        text: String,
        meta: ChunkMeta = .init()
    ) {
        self.id = id
        self.documentID = documentID
        self.ordinal = ordinal
        self.text = text
        self.meta = meta
    }
}

public struct ChunkMeta: Sendable, Hashable, Codable {
    public var page: Int?
    public var section: String?
    public var language: String?
    public var tokenCount: Int?

    public init(page: Int? = nil, section: String? = nil, language: String? = nil, tokenCount: Int? = nil) {
        self.page = page
        self.section = section
        self.language = language
        self.tokenCount = tokenCount
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatProviders

public protocol Embedder: Sendable {
    var dim: Int { get }
    var kind: EmbedderKind { get }
    var modelID: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum EmbedderError: Error, Sendable, Equatable {
    case emptyInput
    case dimensionMismatch(expected: Int, got: Int)
    case unavailable(String)
}

/// Calls an `LLMProvider.embed`-compatible endpoint. Useful for OpenAI-style
/// servers where high-quality embeddings are available.
public struct RemoteEmbedder: Embedder {
    public let kind: EmbedderKind = .openAICompatible
    public let provider: any LLMProvider
    public let modelID: String
    public let dim: Int

    public init(provider: any LLMProvider, modelID: String, dim: Int) {
        self.provider = provider
        self.modelID = modelID
        self.dim = dim
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { throw EmbedderError.emptyInput }
        let result = try await provider.embed(texts, model: modelID)
        for vector in result {
            if vector.count != dim {
                throw EmbedderError.dimensionMismatch(expected: dim, got: vector.count)
            }
        }
        return result
    }
}

/// Stand-in embedder for tests and fallback paths. Produces deterministic
/// L2-normalised vectors from text hashes. Not for production retrieval.
public struct HashEmbedder: Embedder {
    public let kind: EmbedderKind = .test
    public let modelID: String
    public let dim: Int

    public init(modelID: String = "hash:v1", dim: Int = 32) {
        precondition(dim >= 4)
        self.modelID = modelID
        self.dim = dim
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { throw EmbedderError.emptyInput }
        return texts.map { text in
            var vector = [Float](repeating: 0, count: dim)
            for token in tokens(in: text) {
                let bucket = Self.stableHash(token) % UInt64(dim)
                vector[Int(bucket)] += 1
            }
            normalise(&vector)
            return vector
        }
    }

    private func tokens(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .punctuationCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private func normalise(_ vector: inout [Float]) {
        var sum: Float = 0
        for v in vector { sum += v * v }
        guard sum > 0 else { return }
        let scale = 1.0 / sqrt(sum)
        for i in 0..<vector.count { vector[i] *= scale }
    }

    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        return h
    }
}

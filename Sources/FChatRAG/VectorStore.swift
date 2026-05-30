// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Accelerate
import FChatCore

public struct VectorSearchHit: Sendable, Hashable {
    public var chunkID: ChunkID
    public var score: Float
    public init(chunkID: ChunkID, score: Float) {
        self.chunkID = chunkID
        self.score = score
    }
}

public protocol VectorStore: Sendable {
    var dim: Int { get }
    var distance: DistanceMetric { get }
    func upsert(_ entries: [(ChunkID, [Float])]) async throws
    func delete(_ ids: [ChunkID]) async
    func search(query: [Float], topK: Int) async throws -> [VectorSearchHit]
    func count() async -> Int
}

public enum VectorStoreError: Error, Sendable, Equatable {
    case dimensionMismatch(expected: Int, got: Int)
}

/// In-memory brute-force vector store backed by Accelerate. Suitable for
/// personal corpora up to ~100k vectors. Persists nothing on its own.
public actor InMemoryVectorStore: VectorStore {
    public let dim: Int
    public let distance: DistanceMetric
    private var ids: [ChunkID] = []
    private var flat: [Float] = []

    public init(dim: Int, distance: DistanceMetric = .cosine) {
        self.dim = dim
        self.distance = distance
    }

    public func count() -> Int { ids.count }

    public func upsert(_ entries: [(ChunkID, [Float])]) throws {
        for (id, vector) in entries {
            guard vector.count == dim else {
                throw VectorStoreError.dimensionMismatch(expected: dim, got: vector.count)
            }
            let normalised = (distance == .cosine) ? l2Normalised(vector) : vector
            if let existing = ids.firstIndex(of: id) {
                replace(at: existing, with: normalised)
            } else {
                ids.append(id)
                flat.append(contentsOf: normalised)
            }
        }
    }

    public func delete(_ targets: [ChunkID]) {
        let set = Set(targets)
        var keptIDs: [ChunkID] = []
        var keptFlat: [Float] = []
        keptIDs.reserveCapacity(ids.count)
        keptFlat.reserveCapacity(flat.count)
        for (index, id) in ids.enumerated() where !set.contains(id) {
            keptIDs.append(id)
            let start = index * dim
            keptFlat.append(contentsOf: flat[start..<(start + dim)])
        }
        ids = keptIDs
        flat = keptFlat
    }

    public func search(query: [Float], topK: Int) throws -> [VectorSearchHit] {
        guard query.count == dim else { throw VectorStoreError.dimensionMismatch(expected: dim, got: query.count) }
        guard !ids.isEmpty, topK > 0 else { return [] }

        let normalisedQuery: [Float]
        if distance == .cosine {
            normalisedQuery = l2Normalised(query)
        } else {
            normalisedQuery = query
        }

        var scores = [Float](repeating: 0, count: ids.count)
        switch distance {
        case .cosine, .dot:
            // For cosine, both query and stored vectors are pre-normalised, so dot == cosine.
            let n = vDSP_Length(dim)
            for i in 0..<ids.count {
                var score: Float = 0
                flat.withUnsafeBufferPointer { base in
                    normalisedQuery.withUnsafeBufferPointer { qPtr in
                        vDSP_dotpr(base.baseAddress!.advanced(by: i * dim), 1, qPtr.baseAddress!, 1, &score, n)
                    }
                }
                scores[i] = score
            }
        case .l2:
            for i in 0..<ids.count {
                var d: Float = 0
                let start = i * dim
                for j in 0..<dim {
                    let delta = flat[start + j] - normalisedQuery[j]
                    d += delta * delta
                }
                scores[i] = -sqrt(d) // larger == closer, so the same ranking logic works.
            }
        }

        let indices = (0..<ids.count).sorted { scores[$0] > scores[$1] }
        let take = min(topK, indices.count)
        return (0..<take).map { VectorSearchHit(chunkID: ids[indices[$0]], score: scores[indices[$0]]) }
    }

    private func replace(at index: Int, with vector: [Float]) {
        let start = index * dim
        for i in 0..<dim { flat[start + i] = vector[i] }
    }

    private func l2Normalised(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        vDSP_svesq(vector, 1, &sum, vDSP_Length(vector.count))
        let denom = sqrt(sum)
        guard denom > 0 else { return vector }
        var normalised = vector
        var scale = 1.0 / denom
        vDSP_vsmul(vector, 1, &scale, &normalised, 1, vDSP_Length(vector.count))
        return normalised
    }
}

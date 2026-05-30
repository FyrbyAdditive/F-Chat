// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore
@testable import FChatRAG

/// Live tests against the bundled Qwen3-Embedding-4B model. Because the
/// model is vendored into the test target's resources via FChatRAG,
/// these tests just work after `swift build` without any download or
/// environment variable gating.
///
/// They DO load ~2.5 GB into RAM and JIT-compile MLX Metal kernels, so
/// run takes ~10-30s on first invocation (warmup) and ~1-3s per test
/// thereafter. Each test that calls `shared()` reuses the same loaded
/// container.
///
/// If you want to skip these (e.g. on a CI box with no Metal-capable
/// GPU or low RAM), set `FCHAT_SKIP_MLX=1`.
@Suite(
    "MLXQwen3Embedder",
    .disabled(if: ProcessInfo.processInfo.environment["FCHAT_SKIP_MLX"] != nil,
              "set FCHAT_SKIP_MLX=1 to skip MLX tests (e.g. on low-RAM CI)")
)
struct MLXQwen3EmbedderTests {

    @Test func loaderResolvesBundledModelDirectory() throws {
        let url = try MLXEmbedderLoader.bundledModelDirectory()
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: url.path))
        // Sanity: the directory must contain the safetensors weights and
        // the tokenizer config, otherwise the load will fail later.
        #expect(fm.fileExists(atPath: url.appendingPathComponent("model.safetensors").path))
        #expect(fm.fileExists(atPath: url.appendingPathComponent("tokenizer.json").path))
        #expect(fm.fileExists(atPath: url.appendingPathComponent("config.json").path))
    }

    @Test func embedReturnsVectorOfExpectedDim() async throws {
        let container = try await MLXEmbedderLoader.shared.shared()
        let embedder = MLXQwen3Embedder(container: container)
        let vectors = try await embedder.embed(["the quick brown fox"])
        #expect(vectors.count == 1)
        #expect(vectors[0].count == MLXQwen3Embedder.embeddingDim)
    }

    @Test func vectorsAreL2Normalised() async throws {
        let container = try await MLXEmbedderLoader.shared.shared()
        let embedder = MLXQwen3Embedder(container: container)
        let vector = try await embedder.embed(["hello world"])[0]
        var sumSq: Float = 0
        for v in vector { sumSq += v * v }
        let norm = sqrt(sumSq)
        #expect(abs(norm - 1.0) < 0.01, "expected L2 norm ≈ 1.0, got \(norm)")
    }

    @Test func embeddingsAreDeterministicForSameInput() async throws {
        let container = try await MLXEmbedderLoader.shared.shared()
        let embedder = MLXQwen3Embedder(container: container)
        let a = try await embedder.embed(["repeatable text"])[0]
        let b = try await embedder.embed(["repeatable text"])[0]
        // MLX float math at int4 quant may have a tiny amount of jitter
        // depending on how the GPU dispatches the kernel; allow a small
        // tolerance but the vectors should be virtually identical.
        var maxDiff: Float = 0
        for i in 0..<a.count {
            maxDiff = max(maxDiff, abs(a[i] - b[i]))
        }
        #expect(maxDiff < 0.001, "expected near-identical vectors; max diff \(maxDiff)")
    }

    @Test func semanticallySimilarTextsClusterCloser() async throws {
        let container = try await MLXEmbedderLoader.shared.shared()
        let embedder = MLXQwen3Embedder(container: container)
        let vectors = try await embedder.embed([
            "the cat sat on the mat",
            "a feline rested on a rug",
            "monetary policy and inflation expectations",
        ])
        let related = cosine(vectors[0], vectors[1])
        let unrelated = cosine(vectors[0], vectors[2])
        #expect(related > unrelated,
                "expected cat/feline > cat/monetary; got related=\(related), unrelated=\(unrelated)")
    }

    @Test func queryEmbedAppliesInstructionPrefix() async throws {
        let container = try await MLXEmbedderLoader.shared.shared()
        let embedder = MLXQwen3Embedder(container: container)
        let raw = try await embedder.embed(["apple"])[0]
        let asQuery = try await embedder.embedQuery("apple")
        // Different inputs → different vectors. Cosine is high (same word)
        // but they're not identical.
        let c = cosine(raw, asQuery)
        #expect(c > 0.7, "query template should still yield a related vector; cosine=\(c)")
        #expect(c < 0.999, "query template should produce a measurably different vector; cosine=\(c)")
    }

    @Test func batchEmbedsMultipleTextsInOneCall() async throws {
        let container = try await MLXEmbedderLoader.shared.shared()
        let embedder = MLXQwen3Embedder(container: container)
        let vectors = try await embedder.embed(["one", "two", "three"])
        #expect(vectors.count == 3)
        for v in vectors {
            #expect(v.count == MLXQwen3Embedder.embeddingDim)
        }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }
}

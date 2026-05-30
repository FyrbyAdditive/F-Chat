// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatProviders
@testable import FChatRAG

@Suite("Embedders")
struct EmbedderTests {
    @Test func hashEmbedderProducesNormalisedDeterministicVectors() async throws {
        let e = HashEmbedder(dim: 16)
        let a = try await e.embed(["hello world"])
        let b = try await e.embed(["hello world"])
        #expect(a == b)
        let magnitude = sqrt(a[0].reduce(0) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1.0) < 0.001)
    }

    @Test func hashEmbedderEmptyInputThrows() async {
        let e = HashEmbedder(dim: 8)
        do {
            _ = try await e.embed([])
            Issue.record("expected throw")
        } catch EmbedderError.emptyInput {
            // ok
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test func remoteEmbedderProxiesProvider() async throws {
        let provider = MockLLMProvider(embeddings: [
            [0.1, 0.2, 0.3, 0.4],
            [1.0, 0.0, 0.0, 0.0],
        ])
        let remote = RemoteEmbedder(provider: provider, modelID: "text-embedding-3-small", dim: 4)
        let result = try await remote.embed(["a", "b"])
        #expect(result.count == 2)
        #expect(result[0] == [0.1, 0.2, 0.3, 0.4])
    }

    @Test func remoteEmbedderDimMismatchThrows() async {
        let provider = MockLLMProvider(embeddings: [[1, 2, 3]])
        let remote = RemoteEmbedder(provider: provider, modelID: "m", dim: 4)
        do {
            _ = try await remote.embed(["x"])
            Issue.record("expected throw")
        } catch EmbedderError.dimensionMismatch(let exp, let got) {
            #expect(exp == 4 && got == 3)
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }
}

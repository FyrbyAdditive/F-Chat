// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
@testable import FyxLocalRAG

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

}

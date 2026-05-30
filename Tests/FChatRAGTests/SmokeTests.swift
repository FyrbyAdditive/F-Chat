// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FChatRAG

@Suite("RAG smoke")
struct RAGSmokeTests {
    @Test func enumPlaceholder() {
        #expect(EmbedderError.emptyInput == .emptyInput)
    }
}

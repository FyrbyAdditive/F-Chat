// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FChatProviders

@Suite("Providers smoke")
struct ProvidersSmokeTests {
    @Test func errorEquatable() {
        #expect(ProviderError.missingAPIKey == .missingAPIKey)
        #expect(ProviderError.httpStatus(500, body: "x") != .missingAPIKey)
    }
}

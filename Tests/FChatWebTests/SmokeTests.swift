// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FChatWeb

@Suite("Web smoke")
struct WebSmokeTests {
    @Test func errorTypes() {
        #expect(WebSearchError.rateLimited == .rateLimited)
        #expect(WebSearchError.httpStatus(429) != .rateLimited)
    }
}

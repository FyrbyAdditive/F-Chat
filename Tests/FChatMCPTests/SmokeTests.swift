// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FChatMCP

@Suite("MCP smoke")
struct MCPSmokeTests {
    @Test func errorEnumEquatable() {
        #expect(MCPClientError.notInitialized == .notInitialized)
        #expect(MCPClientError.unexpectedResult != .notInitialized)
    }
}

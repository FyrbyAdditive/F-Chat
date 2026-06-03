// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatMCP

/// Regression coverage for the stdio MCP launch crash: pointing a server at a
/// command whose interpreter can't be found launched a child that died
/// instantly, and the next write to its stdin raised SIGPIPE — silently
/// killing the app with no crash report. The fixes: ignore SIGPIPE (so the
/// write throws instead), validate the executable before launch, and give the
/// child a usable PATH.
@Suite("StdioMCPTransport")
struct StdioMCPTransportTests {
    /// A command that doesn't exist (or isn't executable) must throw a
    /// descriptive error from start(), never launch-and-crash.
    @Test func bogusCommandThrowsInsteadOfCrashing() async {
        let t = StdioMCPTransport(command: "/nonexistent/definitely/not/npx")
        await #expect(throws: MCPTransportError.self) {
            try await t.start()
        }
    }

    /// A bare command name that isn't on PATH also throws (resolveExecutable
    /// returns nil) rather than handing Process an invalid executableURL.
    @Test func unresolvableBareNameThrows() async {
        let t = StdioMCPTransport(command: "this-command-does-not-exist-anywhere-xyz")
        await #expect(throws: MCPTransportError.self) {
            try await t.start()
        }
    }

    /// The crash repro, distilled: launch a child that exits immediately (so
    /// its stdin pipe breaks), then write to it. With SIGPIPE ignored the
    /// write must THROW, not terminate the process. We set SIG_IGN here to
    /// mirror what the app does at startup; without the app's fix this test
    /// would itself be killed by SIGPIPE.
    @Test func writeToDeadChildThrowsRatherThanSIGPIPE() async throws {
        signal(SIGPIPE, SIG_IGN)
        // `true` exits 0 immediately and closes its stdin.
        let t = StdioMCPTransport(command: "/usr/bin/true")
        try await t.start()
        // Give the child a moment to exit and the pipe to break.
        try await Task.sleep(nanoseconds: 100_000_000)
        // A frame send writes to the (now broken) stdin pipe.
        let frame = JSONRPCFrame.request(.init(id: .int(1), method: "ping", params: nil))
        await #expect(throws: (any Error).self) {
            try await t.send(frame)
        }
        await t.close()
    }

    /// A command that exists and is executable launches cleanly (no throw).
    @Test func validCommandLaunches() async throws {
        let t = StdioMCPTransport(command: "/bin/cat")  // reads stdin, stays alive
        try await t.start()
        await t.close()
    }
}

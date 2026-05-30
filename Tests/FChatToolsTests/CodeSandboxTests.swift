// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatTools

/// Exercises the code-execution sandbox. These run real `sandbox-exec` +
/// `/bin/bash` child processes, so they're macOS-only and serialized to keep
/// the temp-dir churn predictable. The key assertions are the confinement
/// ones: a script must NOT be able to reach the network or read outside its
/// skill directory.
@Suite("CodeSandbox", .serialized)
struct CodeSandboxTests {
    private func makeSkillDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-sb-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "skill-secret-marker".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func bashEchoReturnsStdout() async throws {
        let dir = try makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sb = CodeSandbox()
        try #require(sb.isAvailable(.bash))
        let r = try await sb.run(language: .bash, code: "echo hello-world", workingDirectory: dir)
        #expect(r.exitCode == 0)
        #expect(r.stdout.contains("hello-world"))
        #expect(!r.timedOut)
    }

    @Test func canReadSkillFilesAndWriteScratch() async throws {
        let dir = try makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sb = CodeSandbox()
        try #require(sb.isAvailable(.bash))
        let r = try await sb.run(
            language: .bash,
            code: "cat SKILL.md && echo wrote > work/out.txt && cat work/out.txt",
            workingDirectory: dir
        )
        #expect(r.exitCode == 0)
        #expect(r.stdout.contains("skill-secret-marker"))
        #expect(r.stdout.contains("wrote"))
    }

    @Test func cannotReadUserHomeDirectory() async throws {
        let dir = try makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The security boundary that matters: a skill must not be able to read
        // the user's home directory (Documents, SSH keys, app state, etc.).
        // Plant a secret directly in the real home and confirm the sandbox
        // blocks reading it.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let secret = home.appendingPathComponent(".fchat-sandbox-test-secret-\(UUID().uuidString)")
        try "TOP-SECRET-HOME-CONTENTS".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }

        let sb = CodeSandbox()
        try #require(sb.isAvailable(.bash))
        let r = try await sb.run(
            language: .bash,
            code: "cat '\(secret.path)' 2>&1; echo DONE",
            workingDirectory: dir
        )
        // The read must be denied: the secret never appears in output.
        #expect(!r.stdout.contains("TOP-SECRET-HOME-CONTENTS"))
        #expect(!r.stderr.contains("TOP-SECRET-HOME-CONTENTS"))
        // The script itself still ran (DONE printed), proving it was the
        // file read that was blocked, not the whole process.
        #expect(r.stdout.contains("DONE"))
    }

    @Test func cannotWriteOutsideScratch() async throws {
        let dir = try makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-sb-escape-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: target) }
        let sb = CodeSandbox()
        try #require(sb.isAvailable(.bash))
        _ = try await sb.run(
            language: .bash,
            code: "echo pwned > '\(target.path)' 2>&1; echo DONE",
            workingDirectory: dir
        )
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func networkIsDenied() async throws {
        let dir = try makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sb = CodeSandbox()
        try #require(sb.isAvailable(.bash))
        // Use bash's /dev/tcp which doesn't depend on curl being present.
        let r = try await sb.run(
            language: .bash,
            code: "(exec 3<>/dev/tcp/example.com/80) 2>&1 && echo CONNECTED || echo BLOCKED",
            workingDirectory: dir,
            timeout: .seconds(10)
        )
        #expect(r.stdout.contains("BLOCKED"))
        #expect(!r.stdout.contains("CONNECTED"))
    }

    @Test func longRunningScriptTimesOut() async throws {
        let dir = try makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sb = CodeSandbox()
        try #require(sb.isAvailable(.bash))
        let r = try await sb.run(language: .bash, code: "sleep 30", workingDirectory: dir, timeout: .seconds(2))
        #expect(r.timedOut)
    }

    @Test func outputBeyondCapIsTruncated() async throws {
        let dir = try makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sb = CodeSandbox()
        try #require(sb.isAvailable(.bash))
        // Emit ~50KB but cap at 1KB.
        let r = try await sb.run(
            language: .bash,
            code: "for i in $(seq 1 5000); do echo 0123456789; done",
            workingDirectory: dir,
            maxOutputBytes: 1024
        )
        #expect(r.truncated)
        #expect(r.stdout.utf8.count <= 1024)
    }

    @Test func pythonRunsAndIsConfinedWhenAvailable() async throws {
        let dir = try makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sb = CodeSandbox()
        // Skip cleanly in environments with no resolvable python3.
        try #require(sb.isAvailable(.python))
        // Runs + writes scratch.
        let run = try await sb.run(
            language: .python,
            code: "import json; open('work/o.json','w').write(json.dumps({'n':6//2})); print(open('work/o.json').read())",
            workingDirectory: dir
        )
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("\"n\": 3"))
        // Still can't read the user's home.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let secret = home.appendingPathComponent(".fchat-py-test-secret-\(UUID().uuidString)")
        try "PYSECRET".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let read = try await sb.run(
            language: .python,
            code: "print(open('\(secret.path)').read())",
            workingDirectory: dir
        )
        #expect(!read.stdout.contains("PYSECRET"))
        #expect(read.exitCode != 0)
    }

    @Test func unavailableInterpreterThrows() async throws {
        let dir = try makeSkillDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Resolver with no python.
        let resolver = CodeSandbox.InterpreterResolver(
            bashPath: { "/bin/bash" },
            pythonPath: { nil }
        )
        let sb = CodeSandbox(resolver: resolver)
        #expect(!sb.isAvailable(.python))
        await #expect(throws: CodeSandbox.SandboxError.self) {
            _ = try await sb.run(language: .python, code: "print(1)", workingDirectory: dir)
        }
    }
}

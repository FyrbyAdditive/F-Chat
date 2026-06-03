// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore

/// Covers the FyxLocal → FyxLocal upgrade migration: the data directory move and
/// the Keychain copy across the bundle-id change. The whole point of the
/// rebrand keeping users' data hinges on these, so they're tested directly.
@Suite("LegacyMigration")
struct LegacyMigrationTests {
    // MARK: - Data directory

    private func tempDir() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fyxmig-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func dataDirMovesWhenOnlyLegacyExists() throws {
        let fm = FileManager.default
        let root = tempDir(); defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("F-Chat", isDirectory: true)
        let new = root.appendingPathComponent("FyxLocal", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: old.appendingPathComponent("state.json"))

        AppDataDirectories.migrate(from: old, to: new)

        #expect(fm.fileExists(atPath: new.appendingPathComponent("state.json").path))
        #expect(!fm.fileExists(atPath: old.path))  // moved, not copied
        let moved = try String(contentsOf: new.appendingPathComponent("state.json"), encoding: .utf8)
        #expect(moved == "hello")
    }

    @Test func dataDirMigrationIsNoOpWhenNewAlreadyExists() throws {
        let fm = FileManager.default
        let root = tempDir(); defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("F-Chat", isDirectory: true)
        let new = root.appendingPathComponent("FyxLocal", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("OLD".utf8).write(to: old.appendingPathComponent("state.json"))
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("NEW".utf8).write(to: new.appendingPathComponent("state.json"))

        AppDataDirectories.migrate(from: old, to: new)

        // New data must never be clobbered by the legacy dir.
        let kept = try String(contentsOf: new.appendingPathComponent("state.json"), encoding: .utf8)
        #expect(kept == "NEW")
        #expect(fm.fileExists(atPath: old.path))  // untouched
    }

    @Test func dataDirMigrationNoOpWhenNothingToMigrate() {
        let fm = FileManager.default
        let root = tempDir(); defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("F-Chat", isDirectory: true)
        let new = root.appendingPathComponent("FyxLocal", isDirectory: true)
        // Neither exists.
        AppDataDirectories.migrate(from: old, to: new)
        #expect(!fm.fileExists(atPath: new.path))
    }

    // MARK: - Keychain

    @Test func keychainSecretsCopiedToNewService() async throws {
        let legacy = InMemorySecretStore()
        let current = InMemorySecretStore()
        await legacy.setSecret("sk-abc", for: "provider:openai:apiKey")
        await legacy.setSecret("tok-123", for: "mcp:server1:oauthAccessToken")

        await LegacyMigration.migrateKeychainIfNeeded(from: legacy, to: current)

        #expect(await current.secret(for: "provider:openai:apiKey") == "sk-abc")
        #expect(await current.secret(for: "mcp:server1:oauthAccessToken") == "tok-123")
    }

    @Test func keychainMigrationDoesNotClobberExistingNewSecrets() async throws {
        let legacy = InMemorySecretStore()
        let current = InMemorySecretStore()
        await legacy.setSecret("OLD", for: "provider:openai:apiKey")
        await current.setSecret("NEW", for: "provider:openai:apiKey")

        // Current already has secrets → migration must be a no-op.
        await LegacyMigration.migrateKeychainIfNeeded(from: legacy, to: current)

        #expect(await current.secret(for: "provider:openai:apiKey") == "NEW")
    }

    @Test func keychainMigrationNoOpWhenLegacyEmpty() async throws {
        let legacy = InMemorySecretStore()
        let current = InMemorySecretStore()
        await LegacyMigration.migrateKeychainIfNeeded(from: legacy, to: current)
        #expect(await current.allAccounts().isEmpty)
    }
}

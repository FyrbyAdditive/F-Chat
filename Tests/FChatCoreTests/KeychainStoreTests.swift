// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore

@Suite("KeychainStore", .serialized)
struct KeychainStoreTests {
    static let testService = "app.fyrby.fchat.tests.\(UUID().uuidString)"

    private func makeStore() -> KeychainStore { KeychainStore(service: Self.testService) }

    private func cleanup() throws {
        let store = makeStore()
        for account in (try? store.allAccounts()) ?? [] {
            try store.deleteSecret(for: account)
        }
    }

    @Test func roundTripStoreAndRetrieve() throws {
        try cleanup()
        let store = makeStore()
        try store.setSecret("hunter2", for: "test:1")
        #expect(try store.secret(for: "test:1") == "hunter2")
        try cleanup()
    }

    @Test func overwriteUpdatesValue() throws {
        try cleanup()
        let store = makeStore()
        try store.setSecret("first", for: "test:2")
        try store.setSecret("second", for: "test:2")
        #expect(try store.secret(for: "test:2") == "second")
        try cleanup()
    }

    @Test func deleteRemovesItem() throws {
        try cleanup()
        let store = makeStore()
        try store.setSecret("doomed", for: "test:3")
        try store.deleteSecret(for: "test:3")
        #expect(try store.secret(for: "test:3") == nil)
    }

    @Test func deleteMissingItemIsNoOp() throws {
        try cleanup()
        let store = makeStore()
        // Should not throw.
        try store.deleteSecret(for: "nope")
    }

    @Test func allAccountsListsKnownKeys() throws {
        try cleanup()
        let store = makeStore()
        try store.setSecret("a", for: "test:a")
        try store.setSecret("b", for: "test:b")
        let accounts = try store.allAccounts().sorted()
        #expect(accounts == ["test:a", "test:b"])
        try cleanup()
    }

    @Test func accountNameHelpers() {
        let pid = ProviderID(rawValue: "default")
        let sid = MCPServerID(rawValue: "everything")
        #expect(KeychainAccount.providerAPIKey(pid) == "provider:default:apiKey")
        #expect(KeychainAccount.mcpAccessToken(sid) == "mcp:everything:oauthAccessToken")
        #expect(KeychainAccount.mcpRefreshToken(sid) == "mcp:everything:oauthRefreshToken")
    }
}

@Suite("InMemorySecretStore")
struct InMemorySecretStoreTests {
    @Test func basicRoundTrip() async throws {
        let store = InMemorySecretStore()
        try await store.setSecret("x", for: "k")
        let value = try await store.secret(for: "k")
        #expect(value == "x")
        try await store.deleteSecret(for: "k")
        let after = try await store.secret(for: "k")
        #expect(after == nil)
    }
}

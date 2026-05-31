// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatTools

@Suite("ContactsSearchTool")
struct ContactsSearchToolTests {

    /// Stub provider: records fetch calls and returns canned data. Mirrors the
    /// StubRetriever / CountingExtractor pattern used by the other tool tests.
    actor StubContacts: ContactsProvider {
        let access: ContactsAccess
        let pool: [ContactRecord]
        private(set) var fetchCalls = 0
        private(set) var lastQuery: String??
        private(set) var lastLimit: Int?

        init(access: ContactsAccess, pool: [ContactRecord] = []) {
            self.access = access
            self.pool = pool
        }
        func authorization() async -> ContactsAccess { access }
        func requestAccess() async -> ContactsAccess { access }
        func fetch(query: String?, limit: Int) async throws -> [ContactRecord] {
            fetchCalls += 1
            lastQuery = query
            lastLimit = limit
            let matched = query.map { q in pool.filter { $0.name.localizedCaseInsensitiveContains(q) } } ?? pool
            return Array(matched.prefix(limit))
        }
    }

    private func sample() -> [ContactRecord] {
        [
            ContactRecord(name: "Alice Smith", givenName: "Alice", familyName: "Smith",
                          emails: ["alice@example.com"], phones: ["+15551234"]),
            ContactRecord(name: "Bob Jones", givenName: "Bob", familyName: "Jones",
                          organization: "Acme", emails: ["bob@acme.test"]),
        ]
    }

    @Test func authorizedSearchReturnsRecords() async throws {
        let stub = StubContacts(access: .authorized, pool: sample())
        let tool = ContactsSearchTool(provider: stub)
        let out = try await tool.invoke(arguments: #"{"query":"alice"}"#)
        #expect(out.isError == false)
        let obj = try JSONSerialization.jsonObject(with: Data(out.outputJSON.utf8)) as? [String: Any]
        let contacts = obj?["contacts"] as? [[String: Any]]
        #expect(contacts?.count == 1)
        #expect((contacts?.first?["emails"] as? [String]) == ["alice@example.com"])
        #expect(await stub.fetchCalls == 1)
    }

    @Test func notDeterminedReturnsErrorAndDoesNotFetch() async throws {
        let stub = StubContacts(access: .notDetermined, pool: sample())
        let tool = ContactsSearchTool(provider: stub)
        let out = try await tool.invoke(arguments: #"{"query":"alice"}"#)
        #expect(out.isError == true)
        #expect(out.outputJSON.contains("Settings"))   // points the user at how to grant
        #expect(await stub.fetchCalls == 0)            // never touched the store
    }

    @Test func deniedReturnsErrorAndDoesNotFetch() async throws {
        let stub = StubContacts(access: .denied, pool: sample())
        let tool = ContactsSearchTool(provider: stub)
        let out = try await tool.invoke(arguments: #"{}"#)
        #expect(out.isError == true)
        #expect(await stub.fetchCalls == 0)
    }

    @Test func limitClampedToMax() async throws {
        let stub = StubContacts(access: .authorized, pool: sample())
        let tool = ContactsSearchTool(provider: stub, defaultLimit: 25, maxLimit: 100)
        _ = try await tool.invoke(arguments: #"{"limit":99999}"#)
        #expect(await stub.lastLimit == 100)
    }

    @Test func listAllPassesNilQuery() async throws {
        let stub = StubContacts(access: .authorized, pool: sample())
        let tool = ContactsSearchTool(provider: stub)
        let out = try await tool.invoke(arguments: #"{}"#)
        #expect(out.isError == false)
        // Empty/missing query → list mode (nil query reaches the provider).
        #expect(await stub.lastQuery == .some(Optional<String>.none))
        let obj = try JSONSerialization.jsonObject(with: Data(out.outputJSON.utf8)) as? [String: Any]
        #expect((obj?["count"] as? Int) == 2)
    }

    @Test func malformedArgsReturnError() async throws {
        let stub = StubContacts(access: .authorized, pool: sample())
        let tool = ContactsSearchTool(provider: stub)
        let out = try await tool.invoke(arguments: #"{"limit":"not-a-number"}"#)
        #expect(out.isError == true)
        #expect(await stub.fetchCalls == 0)
    }
}

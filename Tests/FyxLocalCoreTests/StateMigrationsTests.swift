// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore

/// Covers the versioned `PersistedAppState` migration pipeline — in particular
/// migration #5, which disables the TCC-requiring tools after the bundle-id
/// rename so upgrading users re-grant Calendar/Reminders/Contacts/Location.
@Suite("StateMigrations")
struct StateMigrationsTests {
    /// Build a state at a given schema version with an explicit tool set.
    private func state(version: Int, tools: Set<String>?) -> PersistedAppState {
        PersistedAppState(
            version: version,
            providers: [],
            conversations: [],
            selectedConversationID: nil,
            promptLanguage: .english,
            enabledTools: tools
        )
    }

    @Test func v5DisablesTCCToolsAndKeepsTheRest() {
        let before: Set<String> = [
            "calendar", "calendar_write", "reminders", "reminders_write",
            "contacts_search", "maps",
            "web_search", "web_fetch", "current_time", "make_chart",
            "rag_search", "run_code",
        ]
        let migrated = StateMigrations.migrate(state(version: 4, tools: before))

        // All six TCC tools (incl. write children) gone.
        for t in ["calendar", "calendar_write", "reminders", "reminders_write", "contacts_search", "maps"] {
            #expect(migrated.enabledTools?.contains(t) == false, "\(t) should be disabled")
        }
        // Non-TCC tools untouched.
        for t in ["web_search", "web_fetch", "current_time", "make_chart", "rag_search", "run_code"] {
            #expect(migrated.enabledTools?.contains(t) == true, "\(t) should survive")
        }
        // Version stamped current.
        #expect(migrated.version == StateMigrations.currentVersion)
    }

    @Test func idempotentForCurrentVersion() {
        // A user who RE-enabled Calendar after upgrading (state already at v5)
        // must NOT have it stripped again — the migration keys on version.
        let s = state(version: StateMigrations.currentVersion, tools: ["calendar", "web_search"])
        let migrated = StateMigrations.migrate(s)
        #expect(migrated.enabledTools == ["calendar", "web_search"])
        #expect(migrated.version == StateMigrations.currentVersion)
    }

    @Test func nilToolsIsNoOp() {
        let migrated = StateMigrations.migrate(state(version: 4, tools: nil))
        #expect(migrated.enabledTools == nil)
        #expect(migrated.version == StateMigrations.currentVersion)
    }

    /// Guards the decodable-defaults pitfall: a hand-written v4 JSON (with the
    /// `version` key present) decodes, then migrates cleanly — TCC tools off,
    /// version bumped. This is the shape a real 0.5.1 state.json has.
    @Test func decodesV4JSONThenMigrates() throws {
        let json = """
        {
          "version": 4,
          "providers": [],
          "conversations": [],
          "enabledTools": ["calendar", "maps", "web_search"],
          "promptLanguage": "en"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistedAppState.self, from: Data(json.utf8))
        let migrated = StateMigrations.migrate(decoded)

        #expect(migrated.enabledTools == ["web_search"])
        #expect(migrated.version == StateMigrations.currentVersion)
    }

    /// `AppStateStore.load()` applies migrations AND persists the upgraded
    /// snapshot back to disk (so it doesn't re-run every launch). After loading
    /// a v4 file, the on-disk file must be rewritten at the current version with
    /// the TCC tools removed.
    @Test func loadMigratesAndPersistsToDisk() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("statemig-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = """
        {"version":4,"providers":[],"conversations":[],"enabledTools":["calendar","web_search"],"promptLanguage":"en"}
        """
        try Data(json.utf8).write(to: tmp)

        let store = AppStateStore(fileURL: tmp)
        let loaded = store.load()
        #expect(loaded?.version == StateMigrations.currentVersion)
        #expect(loaded?.enabledTools == ["web_search"])

        // The file on disk was rewritten at the current version.
        let onDisk = try JSONDecoder().decode(PersistedAppState.self, from: Data(contentsOf: tmp))
        #expect(onDisk.version == StateMigrations.currentVersion)
        #expect(onDisk.enabledTools == ["web_search"])
    }
}

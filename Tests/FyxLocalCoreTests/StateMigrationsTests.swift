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
    static let tccNotice = MigrationNotice(titleKey: "migration.v5.tcc.title",
                                           bodyKey: "migration.v5.tcc.body")
    static let localNetworkNotice = MigrationNotice(titleKey: "migration.v6.localnetwork.title",
                                                    bodyKey: "migration.v6.localnetwork.body")

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
        let result = StateMigrations.migrate(state(version: 4, tools: before))

        // All six TCC tools (incl. write children) gone.
        for t in ["calendar", "calendar_write", "reminders", "reminders_write", "contacts_search", "maps"] {
            #expect(result.state.enabledTools?.contains(t) == false, "\(t) should be disabled")
        }
        // Non-TCC tools untouched.
        for t in ["web_search", "web_fetch", "current_time", "make_chart", "rag_search", "run_code"] {
            #expect(result.state.enabledTools?.contains(t) == true, "\(t) should survive")
        }
        // Version stamped current.
        #expect(result.state.version == StateMigrations.currentVersion)
        // From v4: both the v5 TCC notice (tools were on) and the v6
        // local-network notice, in migration order.
        #expect(result.notices == [Self.tccNotice, Self.localNetworkNotice])
    }

    @Test func idempotentForCurrentVersionAndNoNotices() {
        // A user already at the current version: no migration runs, no notices —
        // re-enabled tools are never stripped, the notices never re-show.
        let s = state(version: StateMigrations.currentVersion, tools: ["calendar", "web_search"])
        let result = StateMigrations.migrate(s)
        #expect(result.state.enabledTools == ["calendar", "web_search"])
        #expect(result.state.version == StateMigrations.currentVersion)
        #expect(result.notices.isEmpty)
    }

    @Test func v5StateGetsOnlyLocalNetworkNotice() {
        // Coming from v5 (already past the TCC migration): only the v6
        // local-network notice fires.
        let result = StateMigrations.migrate(state(version: 5, tools: ["calendar", "web_search"]))
        #expect(result.state.version == StateMigrations.currentVersion)
        #expect(result.notices == [Self.localNetworkNotice])
        // v5 already disabled TCC tools; v6 must not strip anything.
        #expect(result.state.enabledTools == ["calendar", "web_search"])
    }

    @Test func nilToolsStillGetsLocalNetworkNotice() {
        // No TCC tools to disable (nil) → no v5 notice, but the v6 local-network
        // notice still fires on any pre-6 upgrade.
        let result = StateMigrations.migrate(state(version: 4, tools: nil))
        #expect(result.state.enabledTools == nil)
        #expect(result.state.version == StateMigrations.currentVersion)
        #expect(result.notices == [Self.localNetworkNotice])
    }

    @Test func noTCCNoticeWhenNoTCCToolsWereEnabled() {
        // The user had no TCC tools on → no v5 notice; only the v6 notice.
        let result = StateMigrations.migrate(state(version: 4, tools: ["web_search", "run_code"]))
        #expect(result.state.version == StateMigrations.currentVersion)
        #expect(result.state.enabledTools == ["web_search", "run_code"])
        #expect(result.notices == [Self.localNetworkNotice])
    }

    /// Guards the decodable-defaults pitfall: a hand-written v4 JSON (with the
    /// `version` key present) decodes, then migrates cleanly — TCC tools off,
    /// version bumped, notice produced. This is the shape a real 0.5.1 state has.
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
        let result = StateMigrations.migrate(decoded)

        #expect(result.state.enabledTools == ["web_search"])
        #expect(result.state.version == StateMigrations.currentVersion)
        #expect(result.notices == [Self.tccNotice, Self.localNetworkNotice])
    }

    /// `AppStateStore.load()` applies migrations, persists the upgraded snapshot
    /// (so it doesn't re-run every launch), AND returns the notices. A second
    /// load of the now-current file migrates nothing and returns no notices.
    @Test func loadMigratesPersistsAndReturnsNotices() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("statemig-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = """
        {"version":4,"providers":[],"conversations":[],"enabledTools":["calendar","web_search"],"promptLanguage":"en"}
        """
        try Data(json.utf8).write(to: tmp)

        let store = AppStateStore(fileURL: tmp)
        let loaded = try #require(store.load())
        #expect(loaded.state.version == StateMigrations.currentVersion)
        #expect(loaded.state.enabledTools == ["web_search"])
        #expect(loaded.notices == [Self.tccNotice, Self.localNetworkNotice])   // both surfaced

        // The file on disk was rewritten at the current version…
        let onDisk = try JSONDecoder().decode(PersistedAppState.self, from: Data(contentsOf: tmp))
        #expect(onDisk.version == StateMigrations.currentVersion)
        #expect(onDisk.enabledTools == ["web_search"])

        // …so a second load migrates nothing and reports no notices (no re-notify).
        let reloaded = try #require(store.load())
        #expect(reloaded.notices.isEmpty)
    }
}

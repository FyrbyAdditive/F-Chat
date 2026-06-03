// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Versioned migrations applied to a decoded `PersistedAppState`.
///
/// This is deliberately separate from `LegacyMigration` (which migrates the
/// on-disk data directory + Keychain across the bundle-id rename, BEFORE state
/// is read). Those are *environment* migrations keyed on the old bundle id;
/// these are *state* migrations keyed on `PersistedAppState.version`.
///
/// Each migration is an isolated `vN_…` pure function. To add the next one:
///   1. bump `currentVersion`,
///   2. add `if s.version < N { s = vN_…(s) }` to `migrate(_:)` in order,
///   3. write the `vN_…` function + a test.
/// Keeping them numbered and pure means every migration is testable in
/// isolation and the history of schema changes reads top-to-bottom.
/// A user-facing notice produced by a migration, shown once on launch. Carries
/// stable localization KEYS (resolved by the UI layer against its string
/// catalog), never finished prose — so Core stays free of UI/localization deps.
public struct MigrationNotice: Equatable, Sendable {
    public let titleKey: String
    public let bodyKey: String
    public init(titleKey: String, bodyKey: String) {
        self.titleKey = titleKey
        self.bodyKey = bodyKey
    }
}

/// The outcome of running `StateMigrations.migrate`: the upgraded state plus any
/// notices the migrations want surfaced to the user (aggregated in order, so a
/// combined multi-version upgrade yields one notice per step that did something).
public struct MigrationResult: Sendable {
    public let state: PersistedAppState
    public let notices: [MigrationNotice]
}

public enum StateMigrations {
    /// The schema version produced by the current build. Equals the highest
    /// migration step below; `migrate(_:)` stamps state to this value.
    public static let currentVersion = 6

    /// Built-in tools that require a macOS TCC permission grant (Calendar,
    /// Reminders, Contacts full-access; Location for Maps' "near me"). Includes
    /// the write-access child toggles, which are meaningless without the parent.
    static let tccTools: Set<String> = [
        "calendar", "calendar_write",
        "reminders", "reminders_write",
        "contacts_search",
        "maps",
    ]

    /// Apply every migration newer than `state.version`, in order, returning the
    /// upgraded state (stamped to `currentVersion`) plus any user notices. Pure —
    /// no I/O, no globals — so it's trivially testable and safe to run on every
    /// load (idempotent once `version` reaches `currentVersion`: no step fires,
    /// no notices). Notices accumulate across steps so a combined upgrade shows
    /// them all; each step only adds a notice if it actually changed this user's
    /// state.
    public static func migrate(_ state: PersistedAppState) -> MigrationResult {
        var s = state
        var notices: [MigrationNotice] = []
        if s.version < 5 {
            let before = s.enabledTools ?? []
            s = v5_disableTCCTools(s)
            // Only notify if at least one TCC tool was actually enabled (and thus
            // turned off) — a user who had them all off needs no explanation.
            if !before.isDisjoint(with: tccTools) {
                notices.append(MigrationNotice(
                    titleKey: "migration.v5.tcc.title",
                    bodyKey: "migration.v5.tcc.body"
                ))
            }
        }
        if s.version < 6 {
            // Informational only — no state change. The bundle-id change also
            // resets the macOS "find devices on your local network" permission;
            // it has no request API, so we just tell the user it'll be asked
            // again the next time the app reaches a local model / MCP server.
            // Always shown on upgrade (don't gate on provider URLs — detecting
            // "local" is unreliable for hostname/`.local`/`.internal` servers).
            notices.append(MigrationNotice(
                titleKey: "migration.v6.localnetwork.title",
                bodyKey: "migration.v6.localnetwork.body"
            ))
        }
        // Future migrations go here, in ascending order:
        // if s.version < 7 { s = v7_…(s); notices.append(…) }
        s.version = currentVersion
        return MigrationResult(state: s, notices: notices)
    }

    /// #5 — disable the TCC-requiring tools.
    ///
    /// The FyxLocal rebrand changed the bundle id, and macOS binds TCC grants
    /// (Calendar/Reminders/Contacts/Location) to the bundle id + signature, so
    /// they don't carry over. A pre-5 state still lists those tools as enabled,
    /// where they'd silently fail until re-granted. Removing them from the
    /// enabled set means the user re-enables in Settings → Tools, which fires
    /// the macOS permission prompt. Keyed on `version`, NOT on tool presence, so
    /// a user who re-enables them after upgrading is never stripped again.
    /// No-op when `enabledTools` is nil (that resolves to defaults, which
    /// contain no TCC tools).
    static func v5_disableTCCTools(_ state: PersistedAppState) -> PersistedAppState {
        guard var tools = state.enabledTools else { return state }
        tools.subtract(tccTools)
        var s = state
        s.enabledTools = tools
        return s
    }
}

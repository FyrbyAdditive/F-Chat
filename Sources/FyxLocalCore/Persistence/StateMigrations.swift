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
public enum StateMigrations {
    /// The schema version produced by the current build. Equals the highest
    /// migration step below; `migrate(_:)` stamps state to this value.
    public static let currentVersion = 5

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
    /// upgraded state stamped to `currentVersion`. Pure — no I/O, no globals —
    /// so it's trivially testable and safe to run on every load (idempotent
    /// once `version` reaches `currentVersion`).
    public static func migrate(_ state: PersistedAppState) -> PersistedAppState {
        var s = state
        if s.version < 5 { s = v5_disableTCCTools(s) }
        // Future migrations go here, in ascending order:
        // if s.version < 6 { s = v6_…(s) }
        s.version = currentVersion
        return s
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

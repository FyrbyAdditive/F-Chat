// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Single source of truth for FyxLocal's on-disk locations under the user's
/// Application Support directory. Used by `AppStateStore` (state.json),
/// `SkillStore` (Skills/), and `RAGDatabase` (rag.sqlite) so the base path is
/// resolved (and the temp-dir fallback applied) in exactly one place.
public enum AppDataDirectories {
    /// The current app data directory name.
    static let dirName = "FyxLocal"
    /// The pre-rename directory name, migrated on first launch (see
    /// `migrateLegacyIfNeeded`). The app used to be called "FyxLocal".
    static let legacyDirName = "F-Chat"

    /// The Application Support base, or the temporary directory as a last-ditch
    /// fallback if it can't be resolved (rare; a filesystem failure).
    private static var applicationSupport: URL {
        (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// `~/Library/Application Support/FyxLocal`. Does not itself create the
    /// directory — use `ensureRoot()` / `subdirectory(_:)` when you need it to
    /// exist (those also run the one-time legacy migration first).
    public static var fyxLocalRoot: URL {
        applicationSupport.appendingPathComponent(dirName, isDirectory: true)
    }

    /// The pre-rename root, `~/Library/Application Support/FyxLocal`.
    static var legacyRoot: URL {
        applicationSupport.appendingPathComponent(legacyDirName, isDirectory: true)
    }

    /// One-time migration of the pre-rename data directory. If the new root does
    /// not exist yet but the legacy "FyxLocal" directory does, move it across so
    /// upgrading users keep their conversations, settings, RAG index, skills and
    /// blobs. Idempotent: once the new root exists this is a no-op, so it's safe
    /// to call on every access. A failed move never throws — the app then simply
    /// starts with an empty (new) directory rather than crashing.
    static func migrateLegacyIfNeeded() {
        migrate(from: legacyRoot, to: fyxLocalRoot)
    }

    /// Path-parameterized core of the data-directory migration (testable with
    /// temp dirs). Moves `old` → `new` only when `new` doesn't exist yet and
    /// `old` does; idempotent and best-effort.
    static func migrate(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            // Cross-volume or permission failure: fall back to a copy so the
            // user still gets their data, leaving the original untouched.
            try? fm.copyItem(at: old, to: new)
        }
    }

    /// `fyxLocalRoot`, created if necessary (after running legacy migration).
    @discardableResult
    public static func ensureRoot() -> URL {
        migrateLegacyIfNeeded()
        let dir = fyxLocalRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A named subdirectory under `fyxLocalRoot`, created if necessary.
    @discardableResult
    public static func subdirectory(_ name: String) -> URL {
        migrateLegacyIfNeeded()
        let dir = fyxLocalRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

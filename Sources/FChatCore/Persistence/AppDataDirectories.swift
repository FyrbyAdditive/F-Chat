// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Single source of truth for F-Chat's on-disk locations under the user's
/// Application Support directory. Used by `AppStateStore` (state.json),
/// `SkillStore` (Skills/), and `RAGDatabase` (rag.sqlite) so the base path is
/// resolved (and the temp-dir fallback applied) in exactly one place.
public enum AppDataDirectories {
    /// `~/Library/Application Support/F-Chat`. Falls back to the temporary
    /// directory if Application Support can't be resolved (rare; would mean a
    /// filesystem failure). Does not itself create the directory — use
    /// `ensureRoot()` / `subdirectory(_:)` when you need it to exist.
    public static var fChatRoot: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("F-Chat", isDirectory: true)
    }

    /// `fChatRoot`, created if necessary.
    @discardableResult
    public static func ensureRoot() -> URL {
        let dir = fChatRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A named subdirectory under `fChatRoot`, created if necessary.
    @discardableResult
    public static func subdirectory(_ name: String) -> URL {
        let dir = fChatRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

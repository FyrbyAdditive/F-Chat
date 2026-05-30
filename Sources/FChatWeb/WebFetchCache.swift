// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// In-memory LRU cache of `web_fetch` results, keyed by the requested URL
/// string. Lets the model re-fetch the same URL within a session without
/// paying network latency or the full-body token cost twice; we serve the
/// (already-clipped) response from cache and the assistant's view of the
/// previous turn's truncated body is preserved by the host conversation
/// history machinery.
///
/// Bounded by a simple LRU. No on-disk persistence — privacy footgun and
/// adds complexity for negligible benefit. Lifetime is the AppEnvironment.
public actor WebFetchCache {
    private struct Entry {
        var page: ExtractedPage
        var lastAccess: Date
    }

    private var entries: [String: Entry] = [:]
    private let limit: Int

    public init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    /// Look up the cached page for `url`. Touches the access time so LRU
    /// reflects the read.
    public func get(_ url: String) -> ExtractedPage? {
        guard var entry = entries[url] else { return nil }
        entry.lastAccess = .now
        entries[url] = entry
        return entry.page
    }

    /// Store / overwrite the cached page for `url`. Evicts the least-recently
    /// accessed entry if we cross the limit.
    public func put(_ url: String, _ page: ExtractedPage) {
        entries[url] = Entry(page: page, lastAccess: .now)
        guard entries.count > limit else { return }
        // Evict the single oldest entry. O(n) over a small dict is fine.
        if let victim = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            entries.removeValue(forKey: victim.key)
        }
    }

    /// Drop all cached entries. Call on conversation reset / sign-out.
    public func clear() {
        entries.removeAll()
    }

    /// Diagnostic: number of currently cached URLs. Used by tests.
    public var count: Int { entries.count }
}

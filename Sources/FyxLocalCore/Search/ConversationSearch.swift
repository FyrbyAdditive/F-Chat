// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public extension Conversation {
    /// Whether this conversation matches a search query, by title OR any
    /// message's plain text. Case-insensitive. An empty/whitespace query
    /// matches everything (so the unfiltered list shows).
    func matches(searchQuery query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(q) { return true }
        return messages.contains { $0.plainText.localizedCaseInsensitiveContains(q) }
    }
}

/// Filter conversations by a search query (title + message text), preserving
/// input order. Pure + testable; the sidebar calls this to drive `.searchable`.
public func conversationsMatching(query: String, in conversations: [Conversation]) -> [Conversation] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return conversations }
    return conversations.filter { $0.matches(searchQuery: q) }
}

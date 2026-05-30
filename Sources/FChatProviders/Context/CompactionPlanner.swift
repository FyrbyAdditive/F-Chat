// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// Decides which messages get summarized away and which stay verbatim
/// when a chat crosses the compaction threshold.
///
/// Strategy: keep the most recent `recentKeepCount` messages verbatim,
/// summarize everything before them. Always keeps at least the start of
/// the user's most recent draft (handled by the payload builder, not here).
public struct CompactionPlanner: Sendable {
    public init() {}

    public func plan(
        messageCount: Int,
        recentKeepCount: Int
    ) -> CompactionPlan {
        if messageCount <= recentKeepCount {
            // Not enough history to compact — keep everything.
            return CompactionPlan(
                summarizeIndices: 0..<0,
                keepIndices: 0..<messageCount
            )
        }
        let pivot = messageCount - recentKeepCount
        return CompactionPlan(
            summarizeIndices: 0..<pivot,
            keepIndices: pivot..<messageCount
        )
    }
}

public struct CompactionPlan: Sendable, Hashable {
    /// Indices of messages that should be condensed into a summary.
    public var summarizeIndices: Range<Int>
    /// Indices of messages that should be sent verbatim.
    public var keepIndices: Range<Int>

    public init(summarizeIndices: Range<Int>, keepIndices: Range<Int>) {
        self.summarizeIndices = summarizeIndices
        self.keepIndices = keepIndices
    }

    public var willCompact: Bool { !summarizeIndices.isEmpty }
}

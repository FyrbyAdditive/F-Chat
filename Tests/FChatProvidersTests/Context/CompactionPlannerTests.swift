// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FChatProviders

@Suite("CompactionPlanner")
struct CompactionPlannerTests {
    let planner = CompactionPlanner()

    @Test func shortConversationsAreNotCompacted() {
        let plan = planner.plan(messageCount: 4, recentKeepCount: 6)
        #expect(!plan.willCompact)
        #expect(plan.summarizeIndices == 0..<0)
        #expect(plan.keepIndices == 0..<4)
    }

    @Test func exactlyAtKeepThresholdNotCompacted() {
        let plan = planner.plan(messageCount: 6, recentKeepCount: 6)
        #expect(!plan.willCompact)
        #expect(plan.keepIndices.count == 6)
    }

    @Test func oneOverThresholdCompactsOneMessage() {
        let plan = planner.plan(messageCount: 7, recentKeepCount: 6)
        #expect(plan.willCompact)
        #expect(plan.summarizeIndices == 0..<1)
        #expect(plan.keepIndices == 1..<7)
    }

    @Test func bigConversationKeepsExactlyRecentN() {
        let plan = planner.plan(messageCount: 50, recentKeepCount: 6)
        #expect(plan.summarizeIndices == 0..<44)
        #expect(plan.keepIndices == 44..<50)
        #expect(plan.keepIndices.count == 6)
    }

    @Test func emptyConversationIsNoOp() {
        let plan = planner.plan(messageCount: 0, recentKeepCount: 6)
        #expect(!plan.willCompact)
        #expect(plan.keepIndices.isEmpty)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FyxLocalCore
@testable import FyxLocalApp

/// Unit tests for the pure selection logic behind sidebar multi-select. The two
/// helpers are static on `AppEnvironment` precisely so they're testable without
/// constructing a live environment (which opens the RAG DB / Keychain).
@MainActor
@Suite("Sidebar multi-select logic")
struct SidebarSelectionTests {

    private func convos(_ n: Int) -> [Conversation] {
        (0..<n).map { i in
            Conversation(title: "C\(i)", settings: ChatSettings(model: "m", providerID: ProviderID(rawValue: "p")))
        }
    }

    // MARK: recencyAnchor (which chat the detail pane shows)

    @Test func singleAddIsTheAnchor() {
        let cs = convos(3)
        let anchor = AppEnvironment.recencyAnchor(
            old: [cs[0].id], new: [cs[0].id, cs[2].id], order: cs, previous: cs[0].id
        )
        #expect(anchor == cs[2].id)   // the newly-added one wins
    }

    @Test func rangeAddPicksTopmostInserted() {
        let cs = convos(5)
        // Added c1,c2,c3 at once → topmost in sidebar order is c1.
        let anchor = AppEnvironment.recencyAnchor(
            old: [cs[0].id], new: [cs[0].id, cs[1].id, cs[2].id, cs[3].id], order: cs, previous: cs[0].id
        )
        #expect(anchor == cs[1].id)
    }

    @Test func shrinkKeepsPreviousIfStillSelected() {
        let cs = convos(3)
        // Deselected c0; previous anchor c2 survives → keep it.
        let anchor = AppEnvironment.recencyAnchor(
            old: [cs[0].id, cs[2].id], new: [cs[2].id], order: cs, previous: cs[2].id
        )
        #expect(anchor == cs[2].id)
    }

    @Test func shrinkReanchorsWhenPreviousGone() {
        let cs = convos(3)
        // Previous anchor c2 was removed; remaining {c0,c1} → topmost c0.
        let anchor = AppEnvironment.recencyAnchor(
            old: [cs[0].id, cs[1].id, cs[2].id], new: [cs[0].id, cs[1].id], order: cs, previous: cs[2].id
        )
        #expect(anchor == cs[0].id)
    }

    @Test func emptySelectionHasNoAnchor() {
        let cs = convos(2)
        #expect(AppEnvironment.recencyAnchor(old: [cs[0].id], new: [], order: cs, previous: cs[0].id) == nil)
    }

    // MARK: reanchorTarget (which chat to select after delete)

    @Test func deletingTopBlockSelectsNextSurvivor() {
        let cs = convos(5)
        let target = AppEnvironment.reanchorTarget(deleting: [cs[0].id, cs[1].id], from: cs)
        #expect(target == cs[2].id)   // first survivor at/after the deleted block
    }

    @Test func deletingMiddleBlockSelectsFollowingSurvivor() {
        let cs = convos(5)
        let target = AppEnvironment.reanchorTarget(deleting: [cs[2].id], from: cs)
        #expect(target == cs[3].id)
    }

    @Test func deletingTailFallsBackToPriorSurvivor() {
        let cs = convos(4)
        // Delete the last two → no survivor after the block → closest above (c1).
        let target = AppEnvironment.reanchorTarget(deleting: [cs[2].id, cs[3].id], from: cs)
        #expect(target == cs[1].id)
    }

    @Test func deletingScatteredSubsetPicksFirstSurvivorAfterFirstDeleted() {
        let cs = convos(5)
        // Delete c1 and c3; first deleted is c1 → first survivor at/after = c2.
        let target = AppEnvironment.reanchorTarget(deleting: [cs[1].id, cs[3].id], from: cs)
        #expect(target == cs[2].id)
    }

    @Test func deletingEverythingHasNoTarget() {
        let cs = convos(3)
        #expect(AppEnvironment.reanchorTarget(deleting: Set(cs.map(\.id)), from: cs) == nil)
    }
}

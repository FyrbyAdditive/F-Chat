// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
@testable import FChatApp

@Suite("ChatTaskContext")
struct ChatTaskContextTests {
    @Test func defaultValueIsEmpty() {
        #expect(ChatTaskContext.attachedCollections.isEmpty)
    }

    @Test func withValueScopesToBody() async {
        let a = CollectionID()
        let b = CollectionID()
        await ChatTaskContext.$attachedCollections.withValue([a, b]) {
            #expect(ChatTaskContext.attachedCollections == [a, b])
            // Mutating the var doesn't escape the scope (TaskLocals are
            // read-only outside of withValue).
        }
        // Out of scope: back to default.
        #expect(ChatTaskContext.attachedCollections.isEmpty)
    }

    @Test func propagatesIntoChildTasks() async {
        // The whole point of using a TaskLocal here is that the tool-call
        // subtasks the chat-turn runner spawns inherit the parent stream's
        // scope. Verify that explicitly so future regressions can't quietly
        // break per-chat isolation.
        let a = CollectionID()
        let captured: [CollectionID] = await ChatTaskContext.$attachedCollections.withValue([a]) {
            // Reading from inside a child Task should still see the parent's
            // scoped value (TaskLocal inheritance).
            let inner = Task { ChatTaskContext.attachedCollections }
            return await inner.value
        }
        #expect(captured == [a])
    }

    @Test func concurrentScopesDoNotLeakAcrossTasks() async {
        // Two parallel tasks each set their own scope; neither should see
        // the other's value. This is the property that makes per-chat
        // streams safe to run concurrently.
        let a = CollectionID()
        let b = CollectionID()
        async let aSaw: [CollectionID] = ChatTaskContext.$attachedCollections.withValue([a]) {
            // small yield so the scheduler is forced to interleave with the
            // sibling task before we read
            try? await Task.sleep(for: .milliseconds(5))
            return ChatTaskContext.attachedCollections
        }
        async let bSaw: [CollectionID] = ChatTaskContext.$attachedCollections.withValue([b]) {
            try? await Task.sleep(for: .milliseconds(5))
            return ChatTaskContext.attachedCollections
        }
        let (av, bv) = await (aSaw, bSaw)
        #expect(av == [a])
        #expect(bv == [b])
    }
}

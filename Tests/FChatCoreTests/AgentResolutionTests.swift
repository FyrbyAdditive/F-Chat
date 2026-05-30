// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore

@Suite("Agent")
struct AgentTests {
    @Test func defaultAgentIDIsStable() {
        // The Default agent's UUID is hard-coded; chats persisted with it
        // must continue to resolve across launches and across reinstalls.
        #expect(AgentID.defaultAgent.rawValue.uuidString == "00000000-0000-0000-0000-000000000001")
    }

    @Test func builtInDefaultHasNoBasePrompt() {
        // The Default agent's defining property: nil basePrompt, which is
        // what makes LocalizedSystemPrompt fall back to the localised
        // F-Chat preamble. Migration depends on this.
        #expect(Agent.builtInDefault.id == .defaultAgent)
        #expect(Agent.builtInDefault.basePrompt == nil)
    }
}

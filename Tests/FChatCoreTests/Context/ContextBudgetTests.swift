// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore

@Suite("ContextBudget")
struct ContextBudgetTests {
    @Test func usesServerHintWhenNoHardCap() {
        let settings = ProviderContextSettings(outputReserve: 4096)
        let model = ModelInfo(id: "x", contextWindow: 196_608)
        let budget = ContextBudget.resolve(settings: settings, model: model)
        #expect(budget.effectiveWindow == 196_608)
        #expect(budget.outputReserve == 4096)
        #expect(budget.compactionTrigger == 196_608 - 4096)
        #expect(budget.safeInputBudget == budget.compactionTrigger)
    }

    @Test func usesHardCapWhenSet() {
        let settings = ProviderContextSettings(hardCap: 32_000, outputReserve: 2048)
        let model = ModelInfo(id: "x", contextWindow: 196_608)
        let budget = ContextBudget.resolve(settings: settings, model: model)
        #expect(budget.effectiveWindow == 32_000)
        #expect(budget.compactionTrigger == 32_000 - 2048)
        #expect(budget.sourceLabel.contains("user cap"))
        #expect(budget.sourceLabel.contains("server"))
    }

    @Test func fallsBackToEightKWhenNoHintAndNoCap() {
        let settings = ProviderContextSettings()
        let budget = ContextBudget.resolve(settings: settings, model: nil)
        #expect(budget.effectiveWindow == 8192)
        #expect(budget.compactionTrigger == 8192 - 4096)
        #expect(budget.sourceLabel.contains("fallback"))
    }

    @Test func triggerClampsToAtLeastOneWhenReserveExceedsWindow() {
        // Pathological: tiny window + large reserve. Trigger must stay
        // ≥ 1 so the math doesn't underflow downstream.
        let settings = ProviderContextSettings(hardCap: 1000, outputReserve: 4096)
        let budget = ContextBudget.resolve(settings: settings, model: nil)
        #expect(budget.compactionTrigger == 1)
        #expect(budget.safeInputBudget == 1)
    }

    @Test func sourceLabelMentionsReserve() {
        let settings = ProviderContextSettings(outputReserve: 4096)
        let model = ModelInfo(id: "x", contextWindow: 196_608)
        let budget = ContextBudget.resolve(settings: settings, model: model)
        #expect(budget.sourceLabel.contains("reserved for reply"))
    }

    @Test func providerContextSettingsClampsOutputReserve() {
        let tiny = ProviderContextSettings(outputReserve: 10)
        #expect(tiny.outputReserve == 256)
        let huge = ProviderContextSettings(outputReserve: 1_000_000)
        #expect(huge.outputReserve == 64_000)
    }

    @Test func providerContextSettingsLegacyCompactThresholdIgnored() throws {
        // Old state.json had compactThreshold; new decoder must accept it
        // (ignore its value) and default outputReserve to 4096.
        let legacy = #"""
        {"hardCap":null,"compactThreshold":0.8,"recentKeepCount":6}
        """#
        let decoded = try JSONDecoder().decode(
            ProviderContextSettings.self,
            from: legacy.data(using: .utf8)!
        )
        #expect(decoded.outputReserve == 4096)
        #expect(decoded.recentKeepCount == 6)
        #expect(decoded.hardCap == nil)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore

/// Covers the per-model vision override resolution that gates image attachments:
/// a user override wins; otherwise the detected model's (catalog-derived)
/// capability applies.
@Suite("Provider vision override")
struct ProviderVisionOverrideTests {
    private func provider(overrides: [ModelOverride] = []) -> ProviderRecord {
        ProviderRecord(
            id: ProviderID(rawValue: "test"),
            displayName: "Test",
            baseURL: URL(string: "https://example.com/v1")!,
            modelOverrides: overrides
        )
    }

    @Test func overrideWinsOverDetected() {
        let p = provider(overrides: [ModelOverride(modelID: "m1", supportsVision: true)])
        // Detected says false, override says true → effective true.
        let detected = ModelInfo(id: "m1", supportsVision: false)
        #expect(p.effectiveModelInfo(detected).supportsVision == true)
        #expect(p.acceptsImages(modelID: "m1", detected: [detected]) == true)
    }

    @Test func overrideCanDisableVision() {
        let p = provider(overrides: [ModelOverride(modelID: "m1", supportsVision: false)])
        let detected = ModelInfo(id: "m1", supportsVision: true)  // catalog said yes
        #expect(p.effectiveModelInfo(detected).supportsVision == false)
        #expect(p.acceptsImages(modelID: "m1", detected: [detected]) == false)
    }

    @Test func fallsBackToDetectedWhenNoOverride() {
        let p = provider()
        let visionModel = ModelInfo(id: "vm", supportsVision: true)
        let textModel = ModelInfo(id: "tm", supportsVision: false)
        #expect(p.effectiveModelInfo(visionModel).supportsVision == true)
        #expect(p.acceptsImages(modelID: "vm", detected: [visionModel, textModel]) == true)
        #expect(p.acceptsImages(modelID: "tm", detected: [visionModel, textModel]) == false)
    }

    @Test func unknownModelNotInDetectedDefaultsFalse() {
        let p = provider()
        #expect(p.acceptsImages(modelID: "ghost", detected: []) == false)
    }
}

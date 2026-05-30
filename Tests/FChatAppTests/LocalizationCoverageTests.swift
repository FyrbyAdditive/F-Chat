// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation

/// Structural guard for the FChatApp Localizable.xcstrings catalog: every
/// key must carry `en`, `sv`, and `da` localizations in `translated` state.
/// Catches the easy regression where a new key gets added but only the
/// source-language side gets filled in (which would mean a sv/da user sees
/// English fallback text). This is not a content-quality check — that's
/// the manual verification walk.
@Suite("Localization coverage")
struct LocalizationCoverageTests {
    /// Languages the app ships UI for. Every catalog key must localize all of
    /// these in `translated` state.
    private let requiredLanguages = ["en", "sv", "da"]

    @Test func everyKeyHasAllLocalizations() throws {
        let url = catalogURL()
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]]
        else {
            Issue.record("catalog at \(url.path) did not parse as expected JSON shape")
            return
        }

        // Helper to assert one language's stringUnit is in translated state.
        func assertTranslated(_ key: String, _ lang: String, _ entry: [String: Any]) {
            guard let localizations = entry["localizations"] as? [String: [String: Any]],
                  let langEntry = localizations[lang],
                  let stringUnit = langEntry["stringUnit"] as? [String: Any]
            else {
                Issue.record("key \(key.debugDescription) missing \(lang) localization")
                return
            }
            let state = stringUnit["state"] as? String ?? ""
            let value = stringUnit["value"] as? String ?? ""
            #expect(state == "translated", "key \(key.debugDescription) \(lang).state = \(state) (expected translated)")
            #expect(!value.isEmpty, "key \(key.debugDescription) \(lang).value is empty")
        }

        // Source language declared at top of file should be "en".
        #expect((root["sourceLanguage"] as? String) == "en")

        for (key, entry) in strings {
            for lang in requiredLanguages {
                assertTranslated(key, lang, entry)
            }
        }

        #expect(strings.count > 0, "catalog had zero keys")
    }

    /// Source-tree path to the catalog. SwiftPM's resource processing splits
    /// this into per-locale .strings files in the test bundle but the
    /// authoritative source is the .xcstrings JSON in the source tree.
    private func catalogURL() -> URL {
        // Tests run from .build/.../Tests/ — climb to the repo root.
        // The test binary itself doesn't ship the catalog, so read from disk.
        var url = URL(fileURLWithPath: #file)
        while url.lastPathComponent != "F-Chat" && url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url
            .appendingPathComponent("Sources")
            .appendingPathComponent("FChatApp")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Localizable.xcstrings")
    }
}

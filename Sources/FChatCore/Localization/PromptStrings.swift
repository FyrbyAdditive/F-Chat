// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Looks up model-facing prompt strings from the `Prompts.xcstrings` catalog
/// bundled in FChatCore, selecting the value for an explicit `PromptLanguage`.
///
/// Why a dedicated helper rather than `NSLocalizedString` / `String(localized:)`:
/// two reasons. First, the prompt language is a *persisted, explicitly-chosen*
/// value (`AppState.promptLanguage`), not necessarily the live system locale, so
/// we must select a specific language rather than relying on Foundation's
/// ambient-locale lookup. Second — and decisively — SwiftPM's `swift build` /
/// `swift test` does NOT compile `.xcstrings` into `.lproj/.strings`; it copies
/// the catalog into the bundle verbatim. (Only xcodebuild, which builds the
/// shipping app, compiles it.) So `localizedString(forKey:)` can't be relied on
/// across both build systems. Instead we parse the catalog JSON directly — it's
/// plain JSON and is present in the bundle under either build system — which
/// makes lookups behave identically in tests and in the app.
///
/// Callers in FChatProviders / FChatTools cannot see FChatCore's `Bundle.module`,
/// so this entry point is `public` and they go through it.
public enum PromptStrings {
    /// Every key present in the catalog. Kept here so a test can assert that
    /// every key resolves in every language (the guard that replaces the
    /// compiler's switch-exhaustiveness check we lose by leaving the inline
    /// switches behind).
    public static let allKeys: [String] = [
        "systemprompt.base",
        "systemprompt.tools",
        "systemprompt.rag",
        "titler.prompt",
        "summarizer.prompt",
        "temporal.full",
        "temporal.dayheader",
        "tool.current_time.desc",
        "tool.calendar.desc",
        "tool.reminders.desc",
        "tool.contacts.desc",
        "tool.maps.desc",
        "tool.web_search.desc",
        "tool.web_fetch.desc",
        "tool.rag_search.desc",
        "tool.make_chart.desc",
    ]

    /// Parsed catalog: key -> (language code -> value). Cached after the first
    /// SUCCESSFUL load. We never cache an empty map: if a load comes back empty
    /// (e.g. the bundle isn't ready yet at first access), the next call retries,
    /// so a transient miss can't get frozen in for the process lifetime.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: [String: [String: String]]?

    private static var catalog: [String: [String: String]] {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, !c.isEmpty { return c }
        let loaded = loadCatalog()
        if !loaded.isEmpty { cached = loaded }
        return loaded
    }

    private static let languageCodes = ["en", "en-GB", "sv", "da"]

    /// Loads the catalog into `key -> (lang -> value)`. Handles BOTH bundle
    /// layouts, because the two build systems emit different things:
    ///   • xcodebuild (the shipping app) COMPILES the catalog to
    ///     `<lang>.lproj/Prompts.strings` and removes the raw `.xcstrings`.
    ///   • `swift build` / `swift test` does NOT compile it — it copies the raw
    ///     `Prompts.xcstrings` verbatim and emits no `.lproj`.
    /// We try the compiled `.lproj/.strings` first, then fall back to parsing
    /// the raw `.xcstrings` JSON, so lookups behave identically either way.
    private static func loadCatalog() -> [String: [String: String]] {
        let compiled = loadFromCompiledStrings()
        if !compiled.isEmpty { return compiled }
        return loadFromRawCatalog()
    }

    /// Read per-language compiled `<lang>.lproj/Prompts.strings` (plist dicts).
    private static func loadFromCompiledStrings() -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for code in languageCodes {
            guard let url = Bundle.module.url(forResource: "Prompts", withExtension: "strings",
                                              subdirectory: nil, localization: code),
                  let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            else { continue }
            for (key, value) in dict {
                result[key, default: [:]][code] = value
            }
        }
        return result
    }

    /// Parse the raw `Prompts.xcstrings` JSON (Apple string-catalog format).
    private static func loadFromRawCatalog() -> [String: [String: String]] {
        guard let url = Bundle.module.url(forResource: "Prompts", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any]
        else { return [:] }

        var result: [String: [String: String]] = [:]
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any] else { continue }
            var byLang: [String: String] = [:]
            for (code, loc) in locs {
                if let loc = loc as? [String: Any],
                   let unit = loc["stringUnit"] as? [String: Any],
                   let value = unit["value"] as? String {
                    byLang[code] = value
                }
            }
            result[key] = byLang
        }
        return result
    }

    /// The catalog string for `key` in `language`. Falls back to the source
    /// language (`en`), then to the key itself, so a miss is visibly wrong
    /// rather than empty.
    public static func string(_ key: String, _ language: PromptLanguage) -> String {
        let byLang = catalog[key]
        return byLang?[language.rawValue] ?? byLang?["en"] ?? key
    }

    /// As `string(_:_:)`, then `String(format:)`-substitutes the `%@`/`%lld`
    /// placeholders with `args`. Uses a POSIX locale so substitution is stable
    /// regardless of the system locale.
    public static func string(_ key: String, _ language: PromptLanguage, _ args: CVarArg...) -> String {
        let template = string(key, language)
        return String(format: template, locale: Locale(identifier: "en_US_POSIX"), arguments: args)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore

@Suite("PromptStrings catalog")
struct PromptStringsTests {
    /// The catalog must actually resolve at runtime for every key in every
    /// language — not silently fall back to the key or to English. This is the
    /// guard that replaces the compiler's switch-exhaustiveness check.
    @Test func everyKeyResolvesInEveryLanguage() {
        for key in PromptStrings.allKeys {
            for language in PromptLanguage.allCases {
                let value = PromptStrings.string(key, language)
                #expect(!value.isEmpty, "empty: \(key) [\(language.rawValue)]")
                #expect(value != key, "fell back to key (missing translation): \(key) [\(language.rawValue)]")
            }
        }
    }

    /// Per-language resolution genuinely differs — proves we're loading the
    /// right `.lproj`, not just the source language for everything.
    @Test func languagesResolveDistinctly() {
        let en = PromptStrings.string("systemprompt.base", .english)
        let sv = PromptStrings.string("systemprompt.base", .swedish)
        let da = PromptStrings.string("systemprompt.base", .danish)
        #expect(en.contains("F-Chat"))
        #expect(sv.contains("svenska"))
        #expect(da.contains("dansk"))
        #expect(en != sv)
        #expect(en != da)
        #expect(sv != da)
    }

    /// The US/UK English split is real, not a silent copy: the one prompt
    /// string that diverges carries British spelling in en-GB and American in en.
    @Test func britishEnglishUsesBritishSpelling() {
        let us = PromptStrings.string("tool.contacts.desc", .english)
        let gb = PromptStrings.string("tool.contacts.desc", .englishGB)
        #expect(us.contains("organization"))
        #expect(gb.contains("organisation"))
        #expect(us != gb)
    }

    /// The `%@` format overload substitutes positional args in order.
    @Test func formatArgsSubstitute() {
        let header = PromptStrings.string("temporal.dayheader", .english,
                                          "Tuesday, May 26, 2026", "Europe/London", "BST")
        #expect(header == "[Today is Tuesday, May 26, 2026; timezone Europe/London (BST)]")
    }
}

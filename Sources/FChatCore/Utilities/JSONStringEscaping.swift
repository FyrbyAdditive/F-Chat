// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public extension String {
    /// Escape backslashes and double-quotes so the string can be embedded in a
    /// hand-built JSON string literal. Several places assemble small JSON
    /// payloads by interpolation (tool errors, temporal context, cleared-result
    /// placeholders) and all need this exact escaping — so it lives in FChatCore
    /// where every module can reach it.
    func escapedForJSON() -> String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `escapedForJSON()` plus collapsing newlines to spaces — for inline,
    /// single-line JSON values (search snippets, fetched-page error text).
    func escapedForJSONInline() -> String {
        escapedForJSON().replacingOccurrences(of: "\n", with: " ")
    }
}

import Foundation

extension String {
    /// Escape backslashes and double-quotes so the string can be embedded in a
    /// hand-built JSON string literal. Built-in tools assemble small JSON error
    /// payloads by interpolation, and they all need this exact escaping.
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

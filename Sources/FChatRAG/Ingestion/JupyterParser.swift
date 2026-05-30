// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// .ipynb is JSON with a top-level `cells` array. Each cell has a `cell_type`
/// (markdown / code / raw) and a `source` that's either a String or an array
/// of strings to be joined. Outputs are dropped — they're often huge (image
/// payloads) and rarely useful for retrieval.
public struct JupyterParser: DocumentParser {
    public let supportedExtensions = ["ipynb"]
    public init() {}

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = root["cells"] as? [[String: Any]]
        else {
            throw DocumentParserError.decodeFailure("ipynb missing cells array")
        }

        let notebookLanguage = (root["metadata"] as? [String: Any])
            .flatMap { ($0["kernelspec"] as? [String: Any])?["language"] as? String }
            ?? "python"

        var sections: [ParsedSection] = []
        var fullText = ""

        for (index, cell) in cells.enumerated() {
            let kind = (cell["cell_type"] as? String) ?? "raw"
            let source = Self.joinSource(cell["source"])
            guard !source.isEmpty else { continue }

            let n = index + 1
            switch kind {
            case "markdown":
                sections.append(ParsedSection(title: "Cell \(n) (markdown)", page: n, text: source))
                fullText += source + "\n\n"
            case "code":
                let fenced = "```\(notebookLanguage)\n\(source)\n```"
                sections.append(ParsedSection(title: "Cell \(n) (code)", page: n, text: fenced))
                fullText += fenced + "\n\n"
            default:
                sections.append(ParsedSection(title: "Cell \(n) (raw)", page: n, text: source))
                fullText += source + "\n\n"
            }
        }

        if sections.isEmpty {
            sections = [ParsedSection(text: "")]
        }
        return ParsedDocument(kind: .jupyter, fullText: fullText, sections: sections)
    }

    private static func joinSource(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [String] { return arr.joined() }
        return ""
    }
}

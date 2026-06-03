// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import ZIPFoundation

/// Builds a *minimal but valid* Office Open XML (`.docx`) document from a list
/// of paragraphs. A `.docx` is just a zip of XML parts; we assemble the fixed
/// scaffold (`[Content_Types].xml`, the two `.rels`) plus a generated
/// `word/document.xml`, then zip them in memory with ZIPFoundation — no Word and
/// no third-party docx dependency required.
///
/// Scope is deliberately small: paragraphs with optional **bold** / *italic*
/// runs (enough for headings and timestamps). No tables, images, or styles —
/// which matches the "prose + reasoning" export fidelity.
enum DocxWriter {
    /// One run of text within a paragraph, with simple character formatting.
    struct Run {
        var text: String
        var bold: Bool = false
        var italic: Bool = false
    }

    /// A paragraph is a list of runs. An empty `runs` list is a blank line.
    struct Paragraph {
        var runs: [Run]
        init(_ runs: [Run]) { self.runs = runs }
        static func plain(_ text: String) -> Paragraph { Paragraph([Run(text: text)]) }
        static let blank = Paragraph([])
    }

    /// Assemble a `.docx` from paragraphs. Throws `ChatExportError.zipFailed` if
    /// the in-memory archive can't be built.
    static func build(paragraphs: [Paragraph]) throws -> Data {
        let parts: [(path: String, contents: String)] = [
            ("[Content_Types].xml", contentTypesXML),
            ("_rels/.rels", rootRelsXML),
            ("word/_rels/document.xml.rels", documentRelsXML),
            ("word/document.xml", documentXML(paragraphs: paragraphs)),
        ]

        do {
            guard let archive = try? Archive(accessMode: .create) else {
                throw ChatExportError.zipFailed("could not create archive")
            }
            for part in parts {
                let bytes = Data(part.contents.utf8)
                try archive.addEntry(
                    with: part.path,
                    type: .file,
                    uncompressedSize: Int64(bytes.count),
                    compressionMethod: .deflate,
                    provider: { position, size in
                        let start = Int(position)
                        return bytes.subdata(in: start ..< start + size)
                    }
                )
            }
            guard let data = archive.data else {
                throw ChatExportError.zipFailed("archive produced no data")
            }
            return data
        } catch let error as ChatExportError {
            throw error
        } catch {
            throw ChatExportError.zipFailed(error.localizedDescription)
        }
    }

    // MARK: - document.xml

    private static func documentXML(paragraphs: [Paragraph]) -> String {
        let body = paragraphs.map(paragraphXML).joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        \(body)<w:sectPr/>
        </w:body>
        </w:document>
        """
    }

    private static func paragraphXML(_ paragraph: Paragraph) -> String {
        guard !paragraph.runs.isEmpty else { return "<w:p/>\n" }
        let runs = paragraph.runs.map(runXML).joined()
        return "<w:p>\(runs)</w:p>\n"
    }

    private static func runXML(_ run: Run) -> String {
        var props = ""
        if run.bold || run.italic {
            props = "<w:rPr>" + (run.bold ? "<w:b/>" : "") + (run.italic ? "<w:i/>" : "") + "</w:rPr>"
        }
        // `xml:space="preserve"` keeps leading/trailing whitespace; the text is
        // XML-escaped (newlines become explicit <w:br/> breaks).
        let segments = xmlEscape(run.text).components(separatedBy: "\n")
        let text = segments
            .map { "<w:t xml:space=\"preserve\">\($0)</w:t>" }
            .joined(separator: "<w:br/>")
        return "<w:r>\(props)\(text)</w:r>"
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Fixed scaffold parts

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let documentRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
    """
}

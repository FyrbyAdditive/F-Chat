// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import ZIPFoundation

/// Builds a valid Office Open XML (`.docx`) document from a list of blocks.
/// A `.docx` is just a zip of XML parts; we assemble the fixed scaffold
/// (`[Content_Types].xml`, the `.rels`, `word/styles.xml`,
/// `word/numbering.xml`) plus a generated `word/document.xml`, then zip them
/// in memory with ZIPFoundation — no Word and no third-party docx dependency.
///
/// Scope matches what the markdown export needs: styled paragraphs (title,
/// headings, quotes, code blocks, horizontal rules), bullet/numbered lists
/// with nesting, simple bordered tables, and runs carrying bold / italic /
/// strikethrough / inline-code / hyperlinks. No images or floating objects.
enum DocxWriter {
    /// One run of text within a paragraph, with character formatting.
    struct Run {
        var text: String
        var bold: Bool = false
        var italic: Bool = false
        var strike: Bool = false
        /// Inline code: monospace + light shading.
        var code: Bool = false
        /// External hyperlink target. The run renders inside `<w:hyperlink>`
        /// with the Hyperlink character style; the URL is registered as an
        /// external relationship in `document.xml.rels`.
        var link: URL? = nil
    }

    /// Paragraph-level styling. Headings/title/quote/code map to named styles
    /// defined in `word/styles.xml`; list items map to the two numbering
    /// definitions in `word/numbering.xml`.
    enum ParagraphStyle: Equatable {
        case body
        case title
        case heading(Int)               // clamped to 1...6
        case quote
        case codeBlock
        case listItem(level: Int, ordered: Bool)  // level clamped to 0...8
        case horizontalRule
    }

    /// A paragraph is a list of runs. An empty `runs` list is a blank line.
    struct Paragraph {
        var runs: [Run]
        var style: ParagraphStyle

        init(_ runs: [Run], style: ParagraphStyle = .body) {
            self.runs = runs
            self.style = style
        }

        static func plain(_ text: String) -> Paragraph { Paragraph([Run(text: text)]) }
        static let blank = Paragraph([])
    }

    /// Top-level document content: flowing paragraphs and tables.
    enum Block {
        case paragraph(Paragraph)
        case table(header: [[Run]], rows: [[[Run]]])

        static func plain(_ text: String) -> Block { .paragraph(.plain(text)) }
        static let blank = Block.paragraph(.blank)
    }

    /// Assemble a `.docx` from blocks. Throws `ChatExportError.zipFailed` if
    /// the in-memory archive can't be built.
    static func build(blocks: [Block]) throws -> Data {
        // Render the body first: hyperlink relationships are discovered
        // during rendering and must land in document.xml.rels.
        var hyperlinks: [URL] = []
        let body = blocks.map { blockXML($0, hyperlinks: &hyperlinks) }.joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>
        \(body)<w:sectPr/>
        </w:body>
        </w:document>
        """

        let parts: [(path: String, contents: String)] = [
            ("[Content_Types].xml", contentTypesXML),
            ("_rels/.rels", rootRelsXML),
            ("word/_rels/document.xml.rels", documentRelsXML(hyperlinks: hyperlinks)),
            ("word/document.xml", document),
            ("word/styles.xml", stylesXML),
            ("word/numbering.xml", numberingXML),
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

    // MARK: - Blocks

    private static func blockXML(_ block: Block, hyperlinks: inout [URL]) -> String {
        switch block {
        case .paragraph(let p):
            return paragraphXML(p, hyperlinks: &hyperlinks)
        case .table(let header, let rows):
            return tableXML(header: header, rows: rows, hyperlinks: &hyperlinks)
        }
    }

    private static func paragraphXML(_ paragraph: Paragraph, hyperlinks: inout [URL]) -> String {
        let pPr = paragraphProperties(paragraph.style)
        guard !paragraph.runs.isEmpty else { return "<w:p>\(pPr)</w:p>\n" }
        let runs = paragraph.runs.map { runOrHyperlinkXML($0, hyperlinks: &hyperlinks) }.joined()
        return "<w:p>\(pPr)\(runs)</w:p>\n"
    }

    private static func paragraphProperties(_ style: ParagraphStyle) -> String {
        switch style {
        case .body:
            return ""
        case .title:
            return "<w:pPr><w:pStyle w:val=\"Title\"/></w:pPr>"
        case .heading(let raw):
            let level = min(max(raw, 1), 6)
            return "<w:pPr><w:pStyle w:val=\"Heading\(level)\"/></w:pPr>"
        case .quote:
            return "<w:pPr><w:pStyle w:val=\"Quote\"/></w:pPr>"
        case .codeBlock:
            return "<w:pPr><w:pStyle w:val=\"CodeBlock\"/></w:pPr>"
        case .listItem(let rawLevel, let ordered):
            let level = min(max(rawLevel, 0), 8)
            let numID = ordered ? 2 : 1
            return "<w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numID)\"/></w:numPr></w:pPr>"
        case .horizontalRule:
            return "<w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"A6A6A6\"/></w:pBdr></w:pPr>"
        }
    }

    // MARK: - Runs

    private static func runOrHyperlinkXML(_ run: Run, hyperlinks: inout [URL]) -> String {
        let inner = runXML(run)
        guard let url = run.link else { return inner }
        // Register (or reuse) the external relationship for this URL.
        let index: Int
        if let existing = hyperlinks.firstIndex(of: url) {
            index = existing
        } else {
            hyperlinks.append(url)
            index = hyperlinks.count - 1
        }
        return "<w:hyperlink r:id=\"\(hyperlinkRelID(index))\">\(inner)</w:hyperlink>"
    }

    /// Hyperlink relationship ids start after the fixed styles/numbering ids.
    static func hyperlinkRelID(_ index: Int) -> String { "rIdLink\(index + 1)" }

    private static func runXML(_ run: Run) -> String {
        var props = ""
        if run.link != nil { props += "<w:rStyle w:val=\"Hyperlink\"/>" }
        if run.bold { props += "<w:b/>" }
        if run.italic { props += "<w:i/>" }
        if run.strike { props += "<w:strike/>" }
        if run.code {
            props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/><w:sz w:val=\"19\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"ECECEC\"/>"
        }
        let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
        // `xml:space="preserve"` keeps leading/trailing whitespace; the text is
        // XML-escaped (newlines become explicit <w:br/> breaks).
        let segments = xmlEscape(run.text).components(separatedBy: "\n")
        let text = segments
            .map { "<w:t xml:space=\"preserve\">\($0)</w:t>" }
            .joined(separator: "<w:br/>")
        return "<w:r>\(rPr)\(text)</w:r>"
    }

    // MARK: - Tables

    private static func tableXML(header: [[Run]], rows: [[[Run]]], hyperlinks: inout [URL]) -> String {
        let border = "<w:top w:val=\"single\" w:sz=\"4\" w:color=\"BFBFBF\"/><w:left w:val=\"single\" w:sz=\"4\" w:color=\"BFBFBF\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"BFBFBF\"/><w:right w:val=\"single\" w:sz=\"4\" w:color=\"BFBFBF\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"BFBFBF\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"BFBFBF\"/>"
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>\(border)</w:tblBorders><w:tblCellMar><w:left w:w=\"108\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr>"

        func cell(_ runs: [Run], shaded: Bool, forceBold: Bool) -> String {
            var content = runs
            if forceBold {
                content = content.map { var r = $0; r.bold = true; return r }
            }
            let shd = shaded ? "<w:tcPr><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/></w:tcPr>" : ""
            let runsXML = content.map { runOrHyperlinkXML($0, hyperlinks: &hyperlinks) }.joined()
            // A table cell must contain at least one paragraph.
            return "<w:tc>\(shd)<w:p>\(runsXML)</w:p></w:tc>"
        }

        if !header.isEmpty {
            xml += "<w:tr>" + header.map { cell($0, shaded: true, forceBold: true) }.joined() + "</w:tr>"
        }
        for row in rows {
            xml += "<w:tr>" + row.map { cell($0, shaded: false, forceBold: false) }.joined() + "</w:tr>"
        }
        xml += "</w:tbl>\n"
        // Word requires a paragraph after a table to separate it from any
        // following table and to end the body cleanly.
        xml += "<w:p/>\n"
        return xml
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
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static func documentRelsXML(hyperlinks: [URL]) -> String {
        var rels = """
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        """
        for (index, url) in hyperlinks.enumerated() {
            let target = xmlEscape(url.absoluteString)
            rels += "\n<Relationship Id=\"\(hyperlinkRelID(index))\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(target)\" TargetMode=\"External\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(rels)
        </Relationships>
        """
    }

    /// Named styles: Title, Heading1–6, Quote, CodeBlock, ListParagraph, and
    /// the Hyperlink character style. Sizes are half-points (`w:sz 28` = 14pt).
    private static let stylesXML: String = {
        func heading(_ level: Int, size: Int) -> String {
            """
            <w:style w:type="paragraph" w:styleId="Heading\(level)">
            <w:name w:val="heading \(level)"/>
            <w:basedOn w:val="Normal"/>
            <w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="\(level - 1)"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="\(size)"/></w:rPr>
            </w:style>
            """
        }
        let headings = [
            heading(1, size: 40), heading(2, size: 32), heading(3, size: 28),
            heading(4, size: 26), heading(5, size: 24), heading(6, size: 22),
        ].joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
        <w:name w:val="Normal"/>
        <w:pPr><w:spacing w:after="120"/></w:pPr>
        </w:style>
        <w:style w:type="paragraph" w:styleId="Title">
        <w:name w:val="Title"/>
        <w:basedOn w:val="Normal"/>
        <w:pPr><w:spacing w:after="240"/></w:pPr>
        <w:rPr><w:b/><w:sz w:val="56"/></w:rPr>
        </w:style>
        \(headings)
        <w:style w:type="paragraph" w:styleId="Quote">
        <w:name w:val="Quote"/>
        <w:basedOn w:val="Normal"/>
        <w:pPr><w:ind w:left="360"/><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="BFBFBF"/></w:pBdr></w:pPr>
        <w:rPr><w:i/><w:color w:val="595959"/></w:rPr>
        </w:style>
        <w:style w:type="paragraph" w:styleId="CodeBlock">
        <w:name w:val="Code Block"/>
        <w:basedOn w:val="Normal"/>
        <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/><w:spacing w:after="0"/><w:ind w:left="113" w:right="113"/></w:pPr>
        <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="19"/></w:rPr>
        </w:style>
        <w:style w:type="paragraph" w:styleId="ListParagraph">
        <w:name w:val="List Paragraph"/>
        <w:basedOn w:val="Normal"/>
        <w:pPr><w:contextualSpacing/></w:pPr>
        </w:style>
        <w:style w:type="character" w:styleId="Hyperlink">
        <w:name w:val="Hyperlink"/>
        <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr>
        </w:style>
        </w:styles>
        """
    }()

    /// Two numbering definitions: numId 1 = bullets (•/◦/▪ cycling by depth),
    /// numId 2 = decimal. Nine levels each, with standard hanging indents.
    private static let numberingXML: String = {
        func levels(ordered: Bool) -> String {
            (0...8).map { level in
                let indent = 720 + level * 360
                let (format, text): (String, String) = ordered
                    ? ("decimal", "%\(level + 1).")
                    : ("bullet", ["•", "◦", "▪"][level % 3])
                return """
                <w:lvl w:ilvl="\(level)">
                <w:start w:val="1"/>
                <w:numFmt w:val="\(format)"/>
                <w:lvlText w:val="\(text)"/>
                <w:lvlJc w:val="left"/>
                <w:pPr><w:ind w:left="\(indent)" w:hanging="360"/></w:pPr>
                </w:lvl>
                """
            }.joined(separator: "\n")
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:abstractNum w:abstractNumId="0">
        \(levels(ordered: false))
        </w:abstractNum>
        <w:abstractNum w:abstractNumId="1">
        \(levels(ordered: true))
        </w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
    }()
}

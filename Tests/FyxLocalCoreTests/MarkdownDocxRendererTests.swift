// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalCore
import ZIPFoundation

/// Markdown → DocxWriter block mapping (renderer level), plus end-to-end
/// document.xml assertions proving the Word export carries real formatting
/// instead of literal markdown syntax.
@Suite("MarkdownDocxRenderer")
struct MarkdownDocxRendererTests {

    // MARK: - Renderer-level shape

    private func paragraphs(_ md: String) -> [DocxWriter.Paragraph] {
        MarkdownDocxRenderer.blocks(from: md).compactMap {
            if case .paragraph(let p) = $0 { return p }
            return nil
        }
    }

    @Test func boldAndItalicBecomeRunFlagsNotLiterals() {
        let ps = paragraphs("plain **bold** and *italic* and ***both***")
        let runs = ps[0].runs
        #expect(!runs.contains { $0.text.contains("*") })
        #expect(runs.contains { $0.text == "bold" && $0.bold && !$0.italic })
        #expect(runs.contains { $0.text == "italic" && $0.italic && !$0.bold })
        #expect(runs.contains { $0.text == "both" && $0.bold && $0.italic })
    }

    @Test func headingLevelsMap() {
        let ps = paragraphs("# One\n\n### Three\n\n####### Seven-clamped")
        #expect(ps[0].style == .heading(1))
        #expect(ps[1].style == .heading(3))
        // CommonMark caps at 6 #s; a 7th renders as text — just assert the
        // first two mapped and nothing crashed.
    }

    @Test func inlineCodeStrikeAndLink() {
        let ps = paragraphs("use `swift build` or ~~make~~ via [docs](https://example.com/d)")
        let runs = ps[0].runs
        #expect(runs.contains { $0.text == "swift build" && $0.code })
        #expect(runs.contains { $0.text == "make" && $0.strike })
        #expect(runs.contains { $0.text == "docs" && $0.link?.absoluteString == "https://example.com/d" })
        #expect(!runs.contains { $0.text.contains("`") || $0.text.contains("~~") || $0.text.contains("](") })
    }

    @Test func nestedListsCarryLevelsAndOrder() {
        let md = """
        - top
          - inner
        1. first
        2. second
        """
        let ps = paragraphs(md)
        #expect(ps[0].style == .listItem(level: 0, ordered: false))
        #expect(ps[1].style == .listItem(level: 1, ordered: false))
        #expect(ps[2].style == .listItem(level: 0, ordered: true))
        #expect(ps[3].style == .listItem(level: 0, ordered: true))
    }

    @Test func fencedCodeSplitsPerLineWithCodeStyle() {
        let ps = paragraphs("```swift\nlet a = 1\nlet b = 2\n```")
        #expect(ps.count == 2)
        #expect(ps.allSatisfy { $0.style == .codeBlock })
        #expect(ps[0].runs[0].text == "let a = 1")
        #expect(ps[1].runs[0].text == "let b = 2")
    }

    @Test func blockQuoteStylesItsParagraphs() {
        let ps = paragraphs("> quoted wisdom")
        #expect(ps[0].style == .quote)
    }

    @Test func tableMapsHeaderAndRows() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let blocks = MarkdownDocxRenderer.blocks(from: md)
        guard case .table(let header, let rows) = blocks.first else {
            Issue.record("expected table, got \(blocks)"); return
        }
        #expect(header.count == 2)
        #expect(header[0].first?.text == "A")
        #expect(rows.count == 1)
        #expect(rows[0][1].first?.text == "2")
    }

    @Test func htmlBlockBecomesLiteralCodeText() {
        let ps = paragraphs("<div onclick=\"x()\">hi</div>")
        #expect(ps[0].style == .codeBlock)
        #expect(ps[0].runs[0].text.contains("<div"))
    }

    @Test func thematicBreakAndImagePlaceholder() {
        let blocks = MarkdownDocxRenderer.blocks(from: "above\n\n---\n\n![cat photo](http://x/c.png)")
        let ps = blocks.compactMap { if case .paragraph(let p) = $0 { return p }; return nil }
        #expect(ps.contains { $0.style == .horizontalRule })
        #expect(ps.contains { $0.runs.contains { $0.text == "(image: cat photo)" } })
    }

    // MARK: - End-to-end document.xml

    private func documentXML(_ markdown: String) throws -> (doc: String, rels: String) {
        var convo = Conversation(
            title: "Fidelity",
            settings: ChatSettings(model: "m", providerID: .init(rawValue: "p"))
        )
        convo.messages = [
            Message(role: .user, contentItems: [.text("q")]),
            Message(role: .assistant, contentItems: [.text(markdown)]),
        ]
        let data = try ChatExporter.docx(convo)
        let archive = try #require(try? Archive(data: data, accessMode: .read))
        func extract(_ path: String) throws -> String {
            let entry = try #require(archive[path])
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        return (try extract("word/document.xml"), try extract("word/_rels/document.xml.rels"))
    }

    @Test func docxCarriesRealFormattingNotMarkdownSyntax() throws {
        let md = """
        # Heading

        Some **bold** and `code` text.

        - item one
        - item two

        | H |
        |---|
        | v |

        [site](https://example.com/page)
        """
        let (doc, rels) = try documentXML(md)
        // Formatting present:
        #expect(doc.contains("Heading1"))                 // heading style
        #expect(doc.contains("<w:b/>"))                   // bold run
        #expect(doc.contains("Menlo"))                    // inline code font
        #expect(doc.contains("<w:numPr>"))                // list numbering
        #expect(doc.contains("<w:tbl>"))                  // real table
        #expect(doc.contains("<w:hyperlink r:id="))       // hyperlink wrap
        // Literal markdown absent:
        #expect(!doc.contains("**"))
        #expect(!doc.contains("# Heading"))
        #expect(!doc.contains("| H |"))
        // Hyperlink relationship registered, external.
        #expect(rels.contains("https://example.com/page"))
        #expect(rels.contains("TargetMode=\"External\""))
    }

    @Test func docxArchiveContainsStyleParts() throws {
        let convo = Conversation(
            title: "T", settings: ChatSettings(model: "m", providerID: .init(rawValue: "p")),
            messages: [Message(role: .user, contentItems: [.text("hello")])]
        )
        let data = try ChatExporter.docx(convo)
        let archive = try #require(try? Archive(data: data, accessMode: .read))
        #expect(archive["word/styles.xml"] != nil)
        #expect(archive["word/numbering.xml"] != nil)
        var ct = Data()
        let entry = try #require(archive["[Content_Types].xml"])
        _ = try archive.extract(entry) { ct.append($0) }
        let types = String(decoding: ct, as: UTF8.self)
        #expect(types.contains("/word/styles.xml"))
        #expect(types.contains("/word/numbering.xml"))
    }

    @Test func escapingStillHoldsInsideFormattedRuns() throws {
        let (doc, _) = try documentXML("**5 < 6 & \"q\"**")
        #expect(doc.contains("&lt;"))
        #expect(doc.contains("&amp;"))
        // Note: swift-markdown smart-quotes plain `"` to curly `“ ”`, which
        // needs no XML escaping — nicer typography for Word, and the raw
        // angle bracket/ampersand still must be escaped.
        #expect(doc.contains("“q”"))
        #expect(!doc.contains("5 < 6"))
    }
}

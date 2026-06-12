// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Markdown

/// Converts a markdown string (CommonMark + GFM, as the models emit) into
/// `DocxWriter` blocks so the Word export carries real formatting instead of
/// literal markdown syntax.
///
/// Mapping:
///   # Heading            → Heading1–6 paragraph styles
///   **bold** *italic*    → run flags (nesting composes)
///   ~~strike~~ `code`    → run flags (code = monospace + shading)
///   [text](url)          → hyperlink runs (external relationship)
///   ```fenced```         → CodeBlock paragraphs (per source line)
///   - / 1. lists         → numbered/bulleted list items, nested via ilvl
///   > quote              → Quote paragraph style
///   | tables |           → bordered tables, shaded bold header
///   ---                  → horizontal-rule paragraph
///   <html>               → rendered as literal code-style text (never markup)
///   ![alt](src)          → "(image: alt)" placeholder text
enum MarkdownDocxRenderer {
    static func blocks(from markdown: String) -> [DocxWriter.Block] {
        let document = Document(parsing: markdown)
        var out: [DocxWriter.Block] = []
        for child in document.blockChildren {
            render(child, into: &out, context: Context())
        }
        return out
    }

    /// Ambient state while walking nested block structure.
    private struct Context {
        /// ≥0 inside a list: the nesting depth for `ilvl`.
        var listLevel: Int = -1
        var listOrdered: Bool = false
        /// Inside a block quote — paragraphs take the Quote style.
        var inQuote: Bool = false

        var paragraphStyle: DocxWriter.ParagraphStyle {
            if listLevel >= 0 { return .listItem(level: listLevel, ordered: listOrdered) }
            if inQuote { return .quote }
            return .body
        }
    }

    // MARK: - Blocks

    private static func render(_ markup: Markup, into out: inout [DocxWriter.Block], context: Context) {
        switch markup {
        case let heading as Heading:
            // Headings inside quotes/lists are rare; the heading style wins.
            out.append(.paragraph(DocxWriter.Paragraph(
                runs(of: heading), style: .heading(heading.level)
            )))

        case let paragraph as Markdown.Paragraph:
            out.append(.paragraph(DocxWriter.Paragraph(
                runs(of: paragraph), style: context.paragraphStyle
            )))

        case let code as CodeBlock:
            var source = code.code
            if source.hasSuffix("\n") { source = String(source.dropLast()) }
            // One CodeBlock paragraph per line: the style zeroes the spacing
            // between them so the block reads contiguous, and Word handles
            // page breaks between lines gracefully.
            for line in source.components(separatedBy: "\n") {
                out.append(.paragraph(DocxWriter.Paragraph(
                    [DocxWriter.Run(text: line)], style: .codeBlock
                )))
            }

        case let quote as BlockQuote:
            var inner = context
            inner.inQuote = true
            for child in quote.blockChildren {
                render(child, into: &out, context: inner)
            }

        case let list as UnorderedList:
            renderList(items: Array(list.listItems), ordered: false, into: &out, context: context)

        case let list as OrderedList:
            renderList(items: Array(list.listItems), ordered: true, into: &out, context: context)

        case let table as Markdown.Table:
            let header: [[DocxWriter.Run]] = table.head.cells.map { runs(of: $0) }
            let rows: [[[DocxWriter.Run]]] = table.body.rows.map { row in
                row.cells.map { runs(of: $0) }
            }
            out.append(.table(header: header, rows: rows))

        case is ThematicBreak:
            out.append(.paragraph(DocxWriter.Paragraph([], style: .horizontalRule)))

        case let html as HTMLBlock:
            // Literal text in code styling — never injected as markup.
            out.append(.paragraph(DocxWriter.Paragraph(
                [DocxWriter.Run(text: html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines))],
                style: .codeBlock
            )))

        default:
            // Unknown block kinds degrade to their plain text.
            let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                out.append(.paragraph(DocxWriter.Paragraph(
                    [DocxWriter.Run(text: text)], style: context.paragraphStyle
                )))
            }
        }
    }

    private static func renderList(
        items: [ListItem],
        ordered: Bool,
        into out: inout [DocxWriter.Block],
        context: Context
    ) {
        var inner = context
        inner.listLevel = context.listLevel + 1
        inner.listOrdered = ordered
        for item in items {
            for child in item.blockChildren {
                render(child, into: &out, context: inner)
            }
        }
    }

    // MARK: - Inlines

    /// Character formatting accumulated while descending inline nesting.
    private struct InlineState {
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var link: URL? = nil
    }

    private static func runs(of container: some Markup) -> [DocxWriter.Run] {
        var runs: [DocxWriter.Run] = []
        for child in container.children {
            appendRuns(for: child, state: InlineState(), into: &runs)
        }
        return runs
    }

    private static func appendRuns(for markup: Markup, state: InlineState, into runs: inout [DocxWriter.Run]) {
        func emit(_ text: String, _ s: InlineState) {
            guard !text.isEmpty else { return }
            runs.append(DocxWriter.Run(
                text: text, bold: s.bold, italic: s.italic,
                strike: s.strike, code: s.code, link: s.link
            ))
        }

        switch markup {
        case let text as Markdown.Text:
            emit(text.string, state)

        case let strong as Strong:
            var s = state; s.bold = true
            for child in strong.children { appendRuns(for: child, state: s, into: &runs) }

        case let emphasis as Emphasis:
            var s = state; s.italic = true
            for child in emphasis.children { appendRuns(for: child, state: s, into: &runs) }

        case let strike as Strikethrough:
            var s = state; s.strike = true
            for child in strike.children { appendRuns(for: child, state: s, into: &runs) }

        case let code as InlineCode:
            var s = state; s.code = true
            emit(code.code, s)

        case let link as Markdown.Link:
            var s = state
            if let destination = link.destination, let url = URL(string: destination) {
                s.link = url
            }
            for child in link.children { appendRuns(for: child, state: s, into: &runs) }

        case let image as Markdown.Image:
            let alt = image.plainText
            emit(alt.isEmpty ? "(image)" : "(image: \(alt))", state)

        case is SoftBreak:
            emit(" ", state)

        case is LineBreak:
            emit("\n", state)

        case let html as InlineHTML:
            // Literal, escaped downstream by DocxWriter — never markup.
            emit(html.rawHTML, state)

        default:
            // Any other inline degrades to its plain text.
            emit(markup.format(), state)
        }
    }
}

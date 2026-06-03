// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import Markdown

/// Renders a CommonMark / GFM markdown source as a vertical stack of SwiftUI
/// views. Inline runs are composed into a single `AttributedString` per
/// paragraph so wrapping behaves naturally; block elements (headings, lists,
/// code blocks, blockquotes, tables, rules) get bespoke layouts.
///
/// Streaming-aware: long sources are parsed on a detached background task and
/// cached as a value-typed `[ParsedBlock]` snapshot. Short sources take a
/// synchronous fast-path so cold-loads of persisted messages don't flash empty.
struct MarkdownView: View {
    let source: String

    /// Sources shorter than this render inline (fast-path) — parse cost is
    /// negligible and a one-frame flash on cold-load would be visible.
    private static let fastPathThreshold: Int = 4000

    /// Minimum interval between background parses while streaming. ~30Hz —
    /// imperceptible lag, bounded CPU.
    private static let throttleInterval: Duration = .milliseconds(33)

    @State private var blocks: [ParsedBlock] = []
    @State private var parsedLength: Int = -1
    @State private var parseTask: Task<Void, Never>?
    @State private var lastParseAt: ContinuousClock.Instant?

    var body: some View {
        Group {
            if source.count < Self.fastPathThreshold {
                // Fast path: parse inline. Cost is negligible for short text,
                // and avoids the one-frame flash from async parsing on cold
                // load of a persisted short message.
                renderBlocks(MarkdownParser.parse(source))
            } else {
                renderBlocks(blocks)
            }
        }
        .onAppear {
            guard source.count >= Self.fastPathThreshold else { return }
            scheduleParse(force: true)
        }
        .onChange(of: source) { _, _ in
            guard source.count >= Self.fastPathThreshold else { return }
            scheduleParse(force: false)
        }
        .onDisappear {
            parseTask?.cancel()
            parseTask = nil
        }
    }

    @ViewBuilder
    private func renderBlocks(_ blocks: [ParsedBlock]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ParsedBlockView(block: block)
            }
        }
    }

    private func scheduleParse(force: Bool) {
        // Skip if a parse for this exact length already landed and the source
        // hasn't changed beyond that.
        if !force, parsedLength == source.count { return }

        // Throttle: if we just parsed, delay until the throttle window passes.
        let now = ContinuousClock.now
        let delay: Duration
        if let last = lastParseAt {
            let elapsed = last.duration(to: now)
            delay = elapsed < Self.throttleInterval ? Self.throttleInterval - elapsed : .zero
        } else {
            delay = .zero
        }

        parseTask?.cancel()
        let snapshot = source
        parseTask = Task.detached(priority: .userInitiated) { [snapshot] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            if Task.isCancelled { return }
            let parsed = MarkdownParser.parse(snapshot)
            if Task.isCancelled { return }
            await MainActor.run {
                self.blocks = parsed
                self.parsedLength = snapshot.count
                self.lastParseAt = ContinuousClock.now
            }
        }
    }
}

// MARK: - ParsedBlock (Sendable snapshot of the parsed markdown)

/// Value-typed snapshot of a single rendered block. `swift-markdown`'s
/// `Markup` protocol is not `Sendable`, so we eagerly convert to this enum on
/// the parse thread and ship it back to MainActor for rendering.
enum ParsedBlock: Sendable, Equatable {
    case heading(level: Int, content: AttributedString)
    case paragraph(AttributedString)
    case unorderedList([ParsedListItem])
    case orderedList(startIndex: Int, items: [ParsedListItem])
    case codeBlock(language: String?, source: String)
    case blockQuote([ParsedBlock])
    case thematicBreak
    case table(header: [AttributedString], rows: [[AttributedString]])
    case htmlBlock(String)
    /// Fallback for block kinds we don't render specially (block directives,
    /// future extensions). Carries the source-formatted text.
    case fallback(String)
}

struct ParsedListItem: Sendable, Equatable {
    let children: [ParsedBlock]
}

// MARK: - MarkdownParser (pure, off-main-safe)

/// Pure function from markdown source to a `Sendable` block snapshot. Safe to
/// call from any actor; the returned value crosses isolation boundaries
/// freely.
enum MarkdownParser {
    static func parse(_ source: String) -> [ParsedBlock] {
        let document = Document(parsing: source, options: [.parseBlockDirectives])
        return document.blockChildren.map(convertBlock)
    }

    private static func convertBlock(_ block: any BlockMarkup) -> ParsedBlock {
        switch block {
        case let heading as Heading:
            return .heading(
                level: heading.level,
                content: InlineRenderer.attributed(from: heading.inlineChildren)
            )

        case let paragraph as Paragraph:
            return .paragraph(InlineRenderer.attributed(from: paragraph.inlineChildren))

        case let list as UnorderedList:
            let items: [ParsedListItem] = list.listItems.map(convertListItem)
            return .unorderedList(items)

        case let list as OrderedList:
            let items: [ParsedListItem] = list.listItems.map(convertListItem)
            return .orderedList(startIndex: Int(list.startIndex), items: items)

        case let code as CodeBlock:
            return .codeBlock(language: code.language, source: code.code)

        case let quote as BlockQuote:
            let children: [ParsedBlock] = quote.blockChildren.map(convertBlock)
            return .blockQuote(children)

        case is ThematicBreak:
            return .thematicBreak

        case let table as Markdown.Table:
            let header: [AttributedString] = table.head.cells.map { cell in
                InlineRenderer.attributed(from: cell.inlineChildren)
            }
            let rows: [[AttributedString]] = table.body.rows.map { row in
                row.cells.map { cell in
                    InlineRenderer.attributed(from: cell.inlineChildren)
                }
            }
            return .table(header: header, rows: rows)

        case let htmlBlock as HTMLBlock:
            return .htmlBlock(htmlBlock.rawHTML)

        default:
            return .fallback(block.format())
        }
    }

    private static func convertListItem(_ item: ListItem) -> ParsedListItem {
        let children: [ParsedBlock] = item.blockChildren.map(convertBlock)
        return ParsedListItem(children: children)
    }
}

// MARK: - Renderer (pure SwiftUI over ParsedBlock)

private struct ParsedBlockView: View {
    let block: ParsedBlock

    var body: some View {
        switch block {
        case .heading(let level, let content):
            Text(content)
                .font(headingFont(for: level))
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .padding(.top, level == 1 ? 8 : 4)

        case .paragraph(let content):
            Text(content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .unorderedList(let items):
            ParsedListView(items: items, ordered: false, startIndex: nil)

        case .orderedList(let startIndex, let items):
            ParsedListView(items: items, ordered: true, startIndex: startIndex)

        case .codeBlock(let language, let source):
            ParsedCodeBlockView(language: language, source: source)

        case .blockQuote(let children):
            ParsedBlockQuoteView(children: children)

        case .thematicBreak:
            Divider().padding(.vertical, 4)

        case .table(let header, let rows):
            ParsedTableView(header: header, rows: rows)

        case .htmlBlock(let raw):
            Text(raw)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

        case .fallback(let text):
            Text(text)
                .textSelection(.enabled)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        case 4: return .headline
        case 5: return .subheadline.bold()
        default: return .body.bold()
        }
    }
}

private struct ParsedListView: View {
    let items: [ParsedListItem]
    let ordered: Bool
    let startIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bullet(for: index))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            ParsedBlockView(block: child)
                        }
                    }
                }
            }
        }
    }

    private func bullet(for index: Int) -> String {
        if ordered { return "\((startIndex ?? 1) + index)." }
        return "•"
    }
}

private struct ParsedCodeBlockView: View {
    let language: String?
    let source: String

    var body: some View {
        let trimmed = source.hasSuffix("\n") ? String(source.dropLast()) : source
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.10))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(trimmed)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct ParsedBlockQuoteView: View {
    let children: [ParsedBlock]

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.4))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    ParsedBlockView(block: child)
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct ParsedTableView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !header.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.callout.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.gray.opacity(0.12))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.gray.opacity(0.05))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - InlineRenderer (pure)

enum InlineRenderer {
    static func attributed(from inlines: some Sequence<InlineMarkup>) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result += render(inline)
        }
        return result
    }

    private static func render(_ inline: InlineMarkup) -> AttributedString {
        switch inline {
        case let text as Markdown.Text:
            return AttributedString(text.string)

        case let emphasis as Emphasis:
            var s = attributed(from: emphasis.inlineChildren)
            s.runs.forEach { run in
                let range = run.range
                var current = s[range].inlinePresentationIntent ?? []
                current.insert(.emphasized)
                s[range].inlinePresentationIntent = current
            }
            return s

        case let strong as Strong:
            var s = attributed(from: strong.inlineChildren)
            s.runs.forEach { run in
                let range = run.range
                var current = s[range].inlinePresentationIntent ?? []
                current.insert(.stronglyEmphasized)
                s[range].inlinePresentationIntent = current
            }
            return s

        case let strike as Strikethrough:
            var s = attributed(from: strike.inlineChildren)
            s.runs.forEach { run in
                let range = run.range
                var current = s[range].inlinePresentationIntent ?? []
                current.insert(.strikethrough)
                s[range].inlinePresentationIntent = current
            }
            return s

        case let code as InlineCode:
            var s = AttributedString(code.code)
            s.inlinePresentationIntent = .code
            return s

        case let link as Markdown.Link:
            var s = attributed(from: link.inlineChildren)
            // Only make a link clickable if its scheme is safe. Model output can
            // contain file://, custom app schemes, etc.; attaching those to
            // `s.link` hands them to the system opener on click. Allowlist the
            // schemes a transcript link should ever use; otherwise render the
            // label as plain (non-clickable) text.
            if let dest = link.destination,
               let url = URL(string: dest),
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                s.link = url
            }
            return s

        case let image as Markdown.Image:
            // Inline image — fall back to alt-text in the text run; the
            // assistant rarely emits raw inline image markup in chat, and
            // bespoke inline image rendering is out of scope.
            let altParts: [String] = image.inlineChildren.compactMap { ($0 as? Markdown.Text)?.string }
            let alt = altParts.joined()
            let label: String
            if !alt.isEmpty {
                label = alt
            } else if let title = image.title, !title.isEmpty {
                label = title
            } else if let source = image.source, !source.isEmpty {
                label = source
            } else {
                label = "image"
            }
            var s = AttributedString("[\(label)]")
            s.inlinePresentationIntent = .emphasized
            return s

        case is LineBreak:
            return AttributedString("\n")

        case is SoftBreak:
            return AttributedString(" ")

        case let html as InlineHTML:
            // Render raw HTML as literal text — most chat HTML is decorative
            // (<br>, <details>) and we'd rather show it than silently strip.
            var s = AttributedString(html.rawHTML)
            s.inlinePresentationIntent = .code
            return s

        case let symbol as SymbolLink:
            return AttributedString(symbol.destination ?? "")

        default:
            return AttributedString(inline.format())
        }
    }
}

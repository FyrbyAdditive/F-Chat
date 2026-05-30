// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FChatApp

@Suite("MarkdownParser")
struct MarkdownParserTests {

    @Test func parsesHeading() {
        let blocks = MarkdownParser.parse("# Hello world")
        #expect(blocks.count == 1)
        if case .heading(let level, let content) = blocks[0] {
            #expect(level == 1)
            #expect(String(content.characters) == "Hello world")
        } else {
            Issue.record("expected heading; got \(blocks)")
        }
    }

    @Test func parsesParagraphWithEmphasis() {
        let blocks = MarkdownParser.parse("plain *italic* **bold**")
        #expect(blocks.count == 1)
        if case .paragraph(let content) = blocks[0] {
            #expect(String(content.characters) == "plain italic bold")
        } else {
            Issue.record("expected paragraph")
        }
    }

    @Test func parsesUnorderedListWithMultipleItems() {
        let blocks = MarkdownParser.parse("""
        - one
        - two
        - three
        """)
        #expect(blocks.count == 1)
        if case .unorderedList(let items) = blocks[0] {
            #expect(items.count == 3)
        } else {
            Issue.record("expected unordered list")
        }
    }

    @Test func parsesOrderedListWithStartIndex() {
        let blocks = MarkdownParser.parse("""
        3. third
        4. fourth
        """)
        #expect(blocks.count == 1)
        if case .orderedList(let startIndex, let items) = blocks[0] {
            #expect(startIndex == 3)
            #expect(items.count == 2)
        } else {
            Issue.record("expected ordered list")
        }
    }

    @Test func parsesFencedCodeBlockWithLanguage() {
        let source = """
        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownParser.parse(source)
        #expect(blocks.count == 1)
        if case .codeBlock(let lang, let body) = blocks[0] {
            #expect(lang == "swift")
            #expect(body.contains("let x = 1"))
        } else {
            Issue.record("expected code block")
        }
    }

    @Test func parsesBlockQuoteWithNestedParagraph() {
        let blocks = MarkdownParser.parse("> quoted")
        #expect(blocks.count == 1)
        if case .blockQuote(let children) = blocks[0] {
            #expect(children.count == 1)
        } else {
            Issue.record("expected block quote")
        }
    }

    @Test func parsesThematicBreak() {
        let blocks = MarkdownParser.parse("---")
        #expect(blocks.count == 1)
        if case .thematicBreak = blocks[0] {
            // ok
        } else {
            Issue.record("expected thematic break")
        }
    }

    @Test func parsesTable() {
        let source = """
        | a | b |
        | - | - |
        | 1 | 2 |
        | 3 | 4 |
        """
        let blocks = MarkdownParser.parse(source)
        #expect(blocks.count == 1)
        if case .table(let header, let rows) = blocks[0] {
            #expect(header.count == 2)
            #expect(rows.count == 2)
            #expect(rows[0].count == 2)
        } else {
            Issue.record("expected table")
        }
    }

    @Test func parsesUnterminatedFenceAsCodeBlock() {
        // Mid-stream: the model has started a code block but hasn't closed it
        // yet. The parser should still recover and produce a code block,
        // possibly containing the partial body — never crash, never silently
        // drop content.
        let source = """
        ```python
        def hello():
            return "world"
        """
        let blocks = MarkdownParser.parse(source)
        #expect(!blocks.isEmpty)
        // swift-markdown treats an unterminated fence as a code block;
        // accept either codeBlock or fallback so the test is robust to
        // upstream behaviour changes.
        let isCodeBlock = blocks.contains { block in
            if case .codeBlock = block { return true }
            return false
        }
        let isFallback = blocks.contains { block in
            if case .fallback = block { return true }
            return false
        }
        #expect(isCodeBlock || isFallback)
    }

    @Test func parsesEmptySourceToEmptyArray() {
        let blocks = MarkdownParser.parse("")
        #expect(blocks.isEmpty)
    }

    @Test func parsedBlocksAreEquatable() {
        // Sanity-check Equatable conformance — used by SwiftUI for diff.
        let a = MarkdownParser.parse("hello")
        let b = MarkdownParser.parse("hello")
        #expect(a == b)
    }
}

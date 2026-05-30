// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatRAG

@Suite("DocumentParsers")
struct ParserTests {
    @Test func plainTextRoundTrip() async throws {
        let parser = PlainTextParser()
        let body = "First line\nSecond line\nThird line"
        let parsed = try await parser.parse(data: Data(body.utf8), filename: "notes.txt")
        #expect(parsed.kind == .text)
        #expect(parsed.fullText == body)
        #expect(parsed.sections.count == 1)
    }

    @Test func markdownSplitsByHeading() async throws {
        let md = """
        # Intro

        Hello there.

        ## Details

        More stuff.

        ## More

        Even more.
        """
        let parsed = try await MarkdownParser().parse(data: Data(md.utf8), filename: "doc.md")
        #expect(parsed.kind == .markdown)
        let titles = parsed.sections.compactMap(\.title)
        #expect(titles == ["Intro", "Details", "More"])
    }

    @Test func markdownWithNoHeadingsYieldsOneSection() async throws {
        let parsed = try await MarkdownParser().parse(data: Data("just words\nno headings".utf8), filename: "x.md")
        #expect(parsed.sections.count == 1)
        #expect(parsed.sections[0].title == nil)
    }

    @Test func codeParserTreatsAsSingleSection() async throws {
        let src = "func main() { print(\"hi\") }"
        let parsed = try await CodeParser().parse(data: Data(src.utf8), filename: "Main.swift")
        #expect(parsed.kind == .code)
        #expect(parsed.sections.count == 1)
        #expect(parsed.sections[0].title == "Main.swift")
    }

    @Test func ingestorRoutesByExtension() async throws {
        let ingestor = FileIngestor()
        let mdParsed = try await ingestor.parse(data: Data("# H".utf8), filename: "x.md")
        #expect(mdParsed.kind == .markdown)
        let txtParsed = try await ingestor.parse(data: Data("hi".utf8), filename: "x.txt")
        #expect(txtParsed.kind == .text)
        let codeParsed = try await ingestor.parse(data: Data("let a = 1".utf8), filename: "Foo.swift")
        #expect(codeParsed.kind == .code)
    }

    @Test func unknownExtensionFallsBackToPlainText() async throws {
        let parsed = try await FileIngestor().parse(data: Data("unstructured blob".utf8), filename: "thing.weird")
        #expect(parsed.kind == .text)
    }
}

@Suite("JupyterParser")
struct JupyterParserTests {
    @Test func decodesMarkdownAndCodeCells() async throws {
        let nb: [String: Any] = [
            "cells": [
                [
                    "cell_type": "markdown",
                    "source": ["# Title\n", "Some markdown text."],
                ],
                [
                    "cell_type": "code",
                    "source": "print('hello')\n",
                    "outputs": ["this should be dropped"],
                ],
                [
                    "cell_type": "raw",
                    "source": ["raw cell content"],
                ],
            ],
            "metadata": [
                "kernelspec": [
                    "language": "python",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: nb, options: [])
        let parsed = try await JupyterParser().parse(data: data, filename: "note.ipynb")
        #expect(parsed.kind == .jupyter)
        #expect(parsed.sections.count == 3)
        #expect(parsed.sections[0].title == "Cell 1 (markdown)")
        #expect(parsed.sections[1].title == "Cell 2 (code)")
        #expect(parsed.sections[1].text.contains("```python"))
        #expect(parsed.sections[1].text.contains("print('hello')"))
        #expect(parsed.sections[2].title == "Cell 3 (raw)")
        // Outputs must NOT bleed into chunk text.
        #expect(!parsed.fullText.contains("this should be dropped"))
    }

    @Test func emptySourceCellsSkipped() async throws {
        let nb: [String: Any] = [
            "cells": [
                ["cell_type": "markdown", "source": ""],
                ["cell_type": "markdown", "source": "Hello"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: nb, options: [])
        let parsed = try await JupyterParser().parse(data: data, filename: "x.ipynb")
        #expect(parsed.sections.count == 1)
        #expect(parsed.sections[0].text == "Hello")
    }

    @Test func malformedJSONThrows() async {
        await #expect(throws: DocumentParserError.self) {
            _ = try await JupyterParser().parse(data: Data("not json".utf8), filename: "x.ipynb")
        }
    }
}

#if canImport(AppKit)
@Suite("RTFParser")
struct RTFParserTests {
    @Test func decodesPlainTextFromRTF() async throws {
        let rtf = #"{\rtf1\ansi\ansicpg1252\cocoartf2761 Hello, world from RTF.}"#
        let parsed = try await RTFParser().parse(data: Data(rtf.utf8), filename: "x.rtf")
        #expect(parsed.kind == .rtf)
        #expect(parsed.fullText.contains("Hello, world from RTF."))
    }

    @Test func rejectsNonRTFBytes() async {
        await #expect(throws: DocumentParserError.self) {
            _ = try await RTFParser().parse(data: Data("not rtf at all".utf8), filename: "broken.rtf")
        }
    }
}
#endif

// DOCX/PPTX/HTML parsers exercised separately in OfficeParserTests +
// HTMLParserTests (binary/web fixtures live there).

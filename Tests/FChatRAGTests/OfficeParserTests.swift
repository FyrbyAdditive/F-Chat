// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import ZIPFoundation
@testable import FChatRAG

@Suite("DocxParser")
struct DocxParserTests {
    @Test func parsesParagraphsAndHeadings() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p>
              <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
              <w:r><w:t>Introduction</w:t></w:r>
            </w:p>
            <w:p>
              <w:r><w:t>Hello world.</w:t></w:r>
            </w:p>
            <w:p>
              <w:pPr><w:pStyle w:val="Heading2"/></w:pPr>
              <w:r><w:t>Details</w:t></w:r>
            </w:p>
            <w:p>
              <w:r><w:t>More text here.</w:t></w:r>
            </w:p>
          </w:body>
        </w:document>
        """
        let data = try makeDocx(documentXML: xml)
        let parsed = try await DocxParser().parse(data: data, filename: "test.docx")

        #expect(parsed.kind == .docx)
        let titles = parsed.sections.compactMap(\.title)
        #expect(titles.contains("Introduction"))
        #expect(titles.contains("Details"))
        #expect(parsed.fullText.contains("Hello world."))
        #expect(parsed.fullText.contains("More text here."))
    }

    @Test func handlesListBullets() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p>
              <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
              <w:r><w:t>First item</w:t></w:r>
            </w:p>
            <w:p>
              <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
              <w:r><w:t>Second item</w:t></w:r>
            </w:p>
          </w:body>
        </w:document>
        """
        let data = try makeDocx(documentXML: xml)
        let parsed = try await DocxParser().parse(data: data, filename: "list.docx")
        #expect(parsed.fullText.contains("- First item"))
        #expect(parsed.fullText.contains("- Second item"))
    }

    @Test func handlesTables() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:tbl>
              <w:tr>
                <w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc>
                <w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc>
              </w:tr>
              <w:tr>
                <w:tc><w:p><w:r><w:t>A2</w:t></w:r></w:p></w:tc>
                <w:tc><w:p><w:r><w:t>B2</w:t></w:r></w:p></w:tc>
              </w:tr>
            </w:tbl>
          </w:body>
        </w:document>
        """
        let data = try makeDocx(documentXML: xml)
        let parsed = try await DocxParser().parse(data: data, filename: "table.docx")
        #expect(parsed.fullText.contains("A1"))
        #expect(parsed.fullText.contains("B1"))
        #expect(parsed.fullText.contains("A2"))
        #expect(parsed.fullText.contains("B2"))
    }

    @Test func rejectsNonZipBytes() async {
        await #expect(throws: DocumentParserError.self) {
            _ = try await DocxParser().parse(data: Data("not a zip".utf8), filename: "fake.docx")
        }
    }
}

@Suite("PptxParser")
struct PptxParserTests {
    @Test func parsesSlidesWithTitles() async throws {
        let slide1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld>
            <p:spTree>
              <p:sp><p:txBody>
                <a:p><a:r><a:t>Overview</a:t></a:r></a:p>
                <a:p><a:r><a:t>This is the body of slide one.</a:t></a:r></a:p>
              </p:txBody></p:sp>
            </p:spTree>
          </p:cSld>
        </p:sld>
        """
        let slide2 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld>
            <p:spTree>
              <p:sp><p:txBody>
                <a:p><a:r><a:t>Conclusion</a:t></a:r></a:p>
                <a:p><a:r><a:t>Wrap up here.</a:t></a:r></a:p>
              </p:txBody></p:sp>
            </p:spTree>
          </p:cSld>
        </p:sld>
        """
        let data = try makePptx(slides: [slide1, slide2])
        let parsed = try await PptxParser().parse(data: data, filename: "deck.pptx")

        #expect(parsed.kind == .pptx)
        #expect(parsed.sections.count == 2)
        #expect(parsed.sections[0].title == "Overview")
        #expect(parsed.sections[0].page == 1)
        #expect(parsed.sections[0].text.contains("body of slide one"))
        #expect(parsed.sections[1].title == "Conclusion")
        #expect(parsed.sections[1].page == 2)
    }

    @Test func includesSpeakerNotes() async throws {
        let slide = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody>
            <a:p><a:r><a:t>Topic</a:t></a:r></a:p>
            <a:p><a:r><a:t>main slide content</a:t></a:r></a:p>
          </p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """
        let notes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody>
            <a:p><a:r><a:t>Remember to thank the team.</a:t></a:r></a:p>
          </p:txBody></p:sp></p:spTree></p:cSld>
        </p:notes>
        """
        let data = try makePptx(slides: [slide], notes: [1: notes])
        let parsed = try await PptxParser().parse(data: data, filename: "deck.pptx")
        #expect(parsed.sections[0].text.contains("Speaker notes:"))
        #expect(parsed.sections[0].text.contains("Remember to thank the team."))
    }

    @Test func rejectsEmptyZipWithoutSlides() async {
        // A valid zip but no ppt/slides/* entries — should fail with decodeFailure.
        let data = (try? makePptx(slides: [])) ?? Data()
        await #expect(throws: DocumentParserError.self) {
            _ = try await PptxParser().parse(data: data, filename: "empty.pptx")
        }
    }
}

// MARK: - Helpers

/// Build a minimal valid .docx archive containing just `word/document.xml`.
/// The parser doesn't look at the rest of the OOXML scaffolding, so we can
/// skip it entirely for test purposes.
private func makeDocx(documentXML: String) throws -> Data {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("docx-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let outURL = dir.appendingPathComponent("out.docx")
    let archive = try Archive(url: outURL, accessMode: .create)
    let xmlData = Data(documentXML.utf8)
    try archive.addEntry(
        with: "word/document.xml",
        type: .file,
        uncompressedSize: Int64(xmlData.count),
        provider: { position, size in
            let start = Int(position)
            let end = min(start + size, xmlData.count)
            return xmlData.subdata(in: start..<end)
        }
    )
    return try Data(contentsOf: outURL)
}

/// Build a minimal valid .pptx archive containing `ppt/slides/slideN.xml`
/// (and optionally matching `ppt/notesSlides/notesSlideN.xml`).
private func makePptx(slides: [String], notes: [Int: String] = [:]) throws -> Data {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pptx-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let outURL = dir.appendingPathComponent("out.pptx")
    let archive = try Archive(url: outURL, accessMode: .create)

    for (index, xml) in slides.enumerated() {
        let path = "ppt/slides/slide\(index + 1).xml"
        let bytes = Data(xml.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(bytes.count),
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, bytes.count)
                return bytes.subdata(in: start..<end)
            }
        )
    }
    for (n, xml) in notes {
        let path = "ppt/notesSlides/notesSlide\(n).xml"
        let bytes = Data(xml.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(bytes.count),
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, bytes.count)
                return bytes.subdata(in: start..<end)
            }
        )
    }
    return try Data(contentsOf: outURL)
}

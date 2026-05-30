// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import ZIPFoundation

// MARK: - DOCX

public struct DocxParser: DocumentParser {
    public let supportedExtensions = ["docx"]
    public init() {}

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentParserError.decodeFailure("docx is not a valid zip: \(error.localizedDescription)")
        }
        guard let documentXMLData = try Self.extract(entry: "word/document.xml", from: archive) else {
            throw DocumentParserError.decodeFailure("docx missing word/document.xml")
        }
        let walker = DocxXMLWalker()
        let parser = XMLParser(data: documentXMLData)
        parser.delegate = walker
        if !parser.parse() {
            throw DocumentParserError.decodeFailure("docx XML parse failed: \(parser.parserError?.localizedDescription ?? "unknown")")
        }
        let sections = walker.finish()
        let fullText = sections.map(\.text).joined(separator: "\n\n")
        return ParsedDocument(kind: .docx, fullText: fullText, sections: sections.isEmpty ? [ParsedSection(text: "")] : sections)
    }

    static func extract(entry path: String, from archive: Archive) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        var bytes = Data()
        _ = try archive.extract(entry) { chunk in bytes.append(chunk) }
        return bytes
    }
}

/// Stateful XMLParser delegate that walks `word/document.xml` and reassembles
/// paragraphs into `ParsedSection` chunks. Heading styles ("Heading1", ...) on
/// a paragraph start a new section; list paragraphs get bullet prefixes; tables
/// flatten cell-by-cell with tabs between cells and newlines between rows.
private final class DocxXMLWalker: NSObject, XMLParserDelegate {
    private var sections: [ParsedSection] = []

    private var currentTitle: String?
    private var currentBuffer: [String] = []

    // Per-paragraph scratchpad.
    private var inParagraph = false
    private var paragraphStyle: String?
    private var paragraphRuns: [String] = []
    private var isList = false

    // Per-text-run scratchpad.
    private var collectingText = false
    private var textBuffer = ""

    // Table state.
    private var inTable = false
    private var inRow = false
    private var rowCells: [String] = []
    private var currentCellRuns: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        switch elementName {
        case "w:tbl":
            // Flush any pending paragraph first.
            flushParagraph()
            inTable = true
        case "w:tr":
            inRow = true
            rowCells = []
        case "w:tc":
            currentCellRuns = []
        case "w:p":
            inParagraph = true
            paragraphStyle = nil
            paragraphRuns = []
            isList = false
        case "w:pStyle":
            if let val = attributeDict["w:val"] {
                paragraphStyle = val
            }
        case "w:numPr":
            isList = true
        case "w:t":
            collectingText = true
            textBuffer = ""
        case "w:tab":
            // Append a tab to whichever buffer is active.
            if collectingText { textBuffer.append("\t") }
        case "w:br":
            if collectingText { textBuffer.append("\n") }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText {
            textBuffer.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "w:t":
            if collectingText {
                if inTable && inRow {
                    currentCellRuns.append(textBuffer)
                } else {
                    paragraphRuns.append(textBuffer)
                }
                textBuffer = ""
                collectingText = false
            }
        case "w:tc":
            rowCells.append(currentCellRuns.joined())
            currentCellRuns = []
        case "w:tr":
            // Append the row as a single paragraph-like line.
            let row = rowCells.joined(separator: "\t")
            if !row.isEmpty {
                appendLine(row)
            }
            inRow = false
            rowCells = []
        case "w:tbl":
            inTable = false
        case "w:p":
            if !inTable {
                flushParagraph()
            } else {
                // Paragraph inside table cell: text already appended to
                // currentCellRuns via w:t handler. Add a soft separator so
                // multi-paragraph cells survive a flatten.
                if !currentCellRuns.isEmpty, !currentCellRuns.last!.hasSuffix(" ") {
                    currentCellRuns[currentCellRuns.count - 1].append(" ")
                }
            }
            inParagraph = false
        default:
            break
        }
    }

    private func flushParagraph() {
        defer {
            paragraphRuns = []
            paragraphStyle = nil
            isList = false
        }
        let joined = paragraphRuns.joined()
        guard !joined.isEmpty else { return }

        // Heading style starts a new section.
        if let style = paragraphStyle, style.lowercased().contains("heading") {
            // Close out the current section, open a new one titled by the heading text.
            flushSection()
            currentTitle = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }

        let line = isList ? "- \(joined)" : joined
        appendLine(line)
    }

    private func appendLine(_ line: String) {
        currentBuffer.append(line)
    }

    private func flushSection() {
        let text = currentBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty || currentTitle != nil {
            sections.append(ParsedSection(title: currentTitle, page: nil, text: text))
        }
        currentBuffer = []
    }

    func finish() -> [ParsedSection] {
        // Final flush.
        flushParagraph()
        flushSection()
        return sections
    }
}

// MARK: - PPTX

public struct PptxParser: DocumentParser {
    public let supportedExtensions = ["pptx"]
    public init() {}

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentParserError.decodeFailure("pptx is not a valid zip: \(error.localizedDescription)")
        }

        // ppt/slides/slide1.xml, slide2.xml, ... sorted by trailing number.
        let slidePaths = Self.sortedEntryPaths(in: archive, prefix: "ppt/slides/slide", suffix: ".xml")
        guard !slidePaths.isEmpty else {
            throw DocumentParserError.decodeFailure("pptx contains no slides")
        }

        var sections: [ParsedSection] = []
        for (index, path) in slidePaths.enumerated() {
            let slideNumber = index + 1
            guard let slideData = try DocxParser.extract(entry: path, from: archive) else { continue }
            let walker = PptxSlideWalker()
            let parser = XMLParser(data: slideData)
            parser.delegate = walker
            _ = parser.parse()
            let (title, body) = walker.finish()

            // Notes for this slide live at ppt/notesSlides/notesSlide{N}.xml.
            let notesPath = "ppt/notesSlides/notesSlide\(slideNumber).xml"
            var notesText = ""
            if let notesData = (try? DocxParser.extract(entry: notesPath, from: archive)) ?? nil {
                let notesWalker = PptxSlideWalker()
                let notesParser = XMLParser(data: notesData)
                notesParser.delegate = notesWalker
                _ = notesParser.parse()
                let (_, notesBody) = notesWalker.finish()
                notesText = notesBody
            }

            var combined = body
            if !notesText.isEmpty {
                combined += combined.isEmpty ? "" : "\n\n"
                combined += "Speaker notes:\n\(notesText)"
            }
            let displayTitle = (title?.isEmpty == false ? title : nil) ?? "Slide \(slideNumber)"
            sections.append(ParsedSection(title: displayTitle, page: slideNumber, text: combined))
        }

        let fullText = sections
            .map { ($0.title.map { "# \($0)\n" } ?? "") + $0.text }
            .joined(separator: "\n\n")
        return ParsedDocument(kind: .pptx, fullText: fullText, sections: sections)
    }

    private static func sortedEntryPaths(in archive: Archive, prefix: String, suffix: String) -> [String] {
        var matches: [(Int, String)] = []
        for entry in archive {
            let path = entry.path
            guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { continue }
            let middle = String(path.dropFirst(prefix.count).dropLast(suffix.count))
            if let n = Int(middle) {
                matches.append((n, path))
            }
        }
        return matches.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}

/// Walks `ppt/slides/slide*.xml`. Concatenates every `<a:t>` text run. Treats
/// the first text-paragraph as the slide title if it's reasonably short.
private final class PptxSlideWalker: NSObject, XMLParserDelegate {
    private var allParagraphs: [String] = []
    private var currentParagraph: [String] = []
    private var collectingText = false
    private var textBuffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        switch elementName {
        case "a:p":
            currentParagraph = []
        case "a:t":
            collectingText = true
            textBuffer = ""
        case "a:br":
            if collectingText { textBuffer.append("\n") }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText {
            textBuffer.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "a:t":
            currentParagraph.append(textBuffer)
            textBuffer = ""
            collectingText = false
        case "a:p":
            let joined = currentParagraph.joined()
            if !joined.isEmpty {
                allParagraphs.append(joined)
            }
            currentParagraph = []
        default:
            break
        }
    }

    /// Returns (title, body). Title = first paragraph if ≤80 chars and there
    /// is more content below it; otherwise nil.
    func finish() -> (String?, String) {
        guard let first = allParagraphs.first else { return (nil, "") }
        if allParagraphs.count > 1 && first.count <= 80 {
            let body = allParagraphs.dropFirst().joined(separator: "\n")
            return (first, body)
        }
        return (nil, allParagraphs.joined(separator: "\n"))
    }
}

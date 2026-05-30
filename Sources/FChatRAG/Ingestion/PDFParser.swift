// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

#if canImport(PDFKit)
import PDFKit

public struct PDFParser: DocumentParser {
    public let supportedExtensions = ["pdf"]
    public init() {}

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        guard let pdf = PDFDocument(data: data) else {
            throw DocumentParserError.decodeFailure("could not open PDF \(filename)")
        }
        var sections: [ParsedSection] = []
        var fullText = ""
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let pageText = page.string ?? ""
            sections.append(ParsedSection(title: nil, page: index + 1, text: pageText))
            fullText += pageText
            fullText += "\n\n"
        }
        return ParsedDocument(kind: .pdf, fullText: fullText, sections: sections)
    }
}
#else
public struct PDFParser: DocumentParser {
    public let supportedExtensions = ["pdf"]
    public init() {}
    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        throw DocumentParserError.parserNotImplemented("PDFKit not available on this platform")
    }
}
#endif

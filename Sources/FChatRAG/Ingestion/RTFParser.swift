// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

#if canImport(AppKit)
import AppKit

public struct RTFParser: DocumentParser {
    public let supportedExtensions = ["rtf", "rtfd"]
    public init() {}

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        guard let s = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else {
            throw DocumentParserError.decodeFailure("rtf decode failed for \(filename)")
        }
        let text = s.string
        return ParsedDocument(kind: .rtf, fullText: text, sections: [ParsedSection(text: text)])
    }
}
#else
public struct RTFParser: DocumentParser {
    public let supportedExtensions = ["rtf", "rtfd"]
    public init() {}
    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        throw DocumentParserError.parserNotImplemented("RTF parsing requires AppKit")
    }
}
#endif

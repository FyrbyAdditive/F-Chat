// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatWeb

public struct FileIngestor: Sendable {
    public let parsers: [any DocumentParser]

    public init(parsers: [any DocumentParser] = FileIngestor.defaultParsers) {
        self.parsers = parsers
    }

    /// Construct an ingestor with the default parser set, sharing the given
    /// `PageExtractor` with the HTML parser (re-uses the WKWebView pool the
    /// `web_fetch` tool already owns).
    public init(pageExtractor: any PageExtractor) {
        self.parsers = FileIngestor.defaultParsers(pageExtractor: pageExtractor)
    }

    public static var defaultParsers: [any DocumentParser] {
        // No-extractor fallback: HTMLParser will throw at parse-time if used.
        defaultParsers(pageExtractor: nil)
    }

    public static func defaultParsers(pageExtractor: (any PageExtractor)?) -> [any DocumentParser] {
        var list: [any DocumentParser] = [
            PlainTextParser(),
            MarkdownParser(),
            JupyterParser(),
            RTFParser(),
            CodeParser(),
            PDFParser(),
            DocxParser(),
            PptxParser(),
        ]
        if let pageExtractor {
            list.append(HTMLParser(extractor: pageExtractor))
        }
        return list
    }

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let parser = parsers.first(where: { $0.supportedExtensions.contains(ext) }) {
            return try await parser.parse(data: data, filename: filename)
        }
        // Fallback: try treating as plain text.
        return try await PlainTextParser().parse(data: data, filename: filename)
    }

    /// Union of every extension every registered parser recognises. Used by
    /// the folder-import path to skip files we couldn't make sense of
    /// anyway (binaries, images, vendored node_modules, etc).
    public var supportedExtensions: Set<String> {
        var union: Set<String> = []
        for parser in parsers {
            union.formUnion(parser.supportedExtensions)
        }
        return union
    }
}

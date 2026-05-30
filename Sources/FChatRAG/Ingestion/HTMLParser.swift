// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatWeb

/// Local-file HTML ingest. Writes the bytes to a temp file, loads them as a
/// `file://` URL via the existing `PageExtractor` infrastructure (same one
/// `web_fetch` uses), and turns the Readability-extracted main content into
/// a single-section `ParsedDocument`.
public struct HTMLParser: DocumentParser {
    public let supportedExtensions = ["html", "htm"]

    private let extractor: any PageExtractor
    private let timeout: TimeInterval

    public init(extractor: any PageExtractor, timeout: TimeInterval = 30) {
        self.extractor = extractor
        self.timeout = timeout
    }

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        let suffix = (filename as NSString).pathExtension.lowercased()
        let ext = suffix.isEmpty ? "html" : suffix
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-html-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let extracted: ExtractedPage
        do {
            extracted = try await extractor.extract(url: tmp, timeout: timeout)
        } catch {
            throw DocumentParserError.decodeFailure("html extract failed: \(error.localizedDescription)")
        }

        let title = (extracted.title?.isEmpty == false ? extracted.title : nil) ?? filename
        let section = ParsedSection(title: title, page: nil, text: extracted.content)
        return ParsedDocument(kind: .html, fullText: extracted.content, sections: [section])
    }
}

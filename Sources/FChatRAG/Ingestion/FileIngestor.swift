import Foundation
import FChatCore

public struct FileIngestor: Sendable {
    public let parsers: [any DocumentParser]

    public init(parsers: [any DocumentParser] = FileIngestor.defaultParsers) {
        self.parsers = parsers
    }

    public static var defaultParsers: [any DocumentParser] {
        [PlainTextParser(), MarkdownParser(), CodeParser(), PDFParser(), DocxParser(), PptxParser()]
    }

    public func parse(data: Data, filename: String) throws -> ParsedDocument {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let parser = parsers.first(where: { $0.supportedExtensions.contains(ext) }) {
            return try parser.parse(data: data, filename: filename)
        }
        // Fallback: try treating as plain text.
        return try PlainTextParser().parse(data: data, filename: filename)
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

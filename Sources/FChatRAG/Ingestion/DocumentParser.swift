// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

public struct ParsedDocument: Sendable, Hashable {
    public var kind: DocumentKind
    public var fullText: String
    public var sections: [ParsedSection]

    public init(kind: DocumentKind, fullText: String, sections: [ParsedSection]) {
        self.kind = kind
        self.fullText = fullText
        self.sections = sections
    }
}

public struct ParsedSection: Sendable, Hashable {
    public var title: String?
    public var page: Int?
    public var text: String
    public init(title: String? = nil, page: Int? = nil, text: String) {
        self.title = title
        self.page = page
        self.text = text
    }
}

public protocol DocumentParser: Sendable {
    var supportedExtensions: [String] { get }
    func parse(data: Data, filename: String) async throws -> ParsedDocument
}

public enum DocumentParserError: Error, Sendable, Equatable {
    case unsupported
    case decodeFailure(String)
    case parserNotImplemented(String)
}

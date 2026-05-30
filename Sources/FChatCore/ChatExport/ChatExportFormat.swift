// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import UniformTypeIdentifiers

/// The file formats F-Chat can export conversations to. Markdown / plain text /
/// Word are human-readable transcripts (prose + reasoning, no tool/image
/// content); JSON is the lossless native format that re-imports with full
/// fidelity.
public enum ChatExportFormat: String, Sendable, Hashable, CaseIterable, Identifiable {
    case markdown
    case json
    case docx
    case plainText

    public var id: String { rawValue }

    /// Extension used for a single exported file (no leading dot).
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        case .docx: return "docx"
        case .plainText: return "txt"
        }
    }

    /// Human label for the format picker.
    public var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .json: return "JSON (re-importable)"
        case .docx: return "Word"
        case .plainText: return "Plain text"
        }
    }

    /// The UTType for a single exported file, used by SwiftUI's `.fileExporter`.
    public var contentType: UTType {
        switch self {
        case .markdown:
            // `.markdown` may be absent on some systems; fall back to a declared
            // .md type, then plain text.
            return UTType(filenameExtension: "md") ?? .plainText
        case .json: return .json
        case .docx:
            return UTType(filenameExtension: "docx")
                ?? UTType("org.openxmlformats.wordprocessingml.document")
                ?? .data
        case .plainText: return .plainText
        }
    }
}

/// A ready-to-write export: the bytes, a suggested filename (with extension),
/// and the UTType so the UI can hand it straight to `.fileExporter`. When more
/// than one chat is exported as a human format, `data` is a `.zip` of one file
/// per chat and `contentType` is `.zip`.
public struct ChatExportBundle: Sendable {
    public let data: Data
    public let suggestedFilename: String
    public let contentType: UTType

    public init(data: Data, suggestedFilename: String, contentType: UTType) {
        self.data = data
        self.suggestedFilename = suggestedFilename
        self.contentType = contentType
    }
}

public enum ChatExportError: Error, CustomStringConvertible, Equatable {
    case nothingSelected
    case encodingFailed(String)
    case zipFailed(String)

    public var description: String {
        switch self {
        case .nothingSelected:
            return "No conversations were selected to export."
        case .encodingFailed(let detail):
            return "Could not encode the export: \(detail)"
        case .zipFailed(let detail):
            return "Could not build the .zip: \(detail)"
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import ZIPFoundation

/// Turns native `Conversation`s into exportable bytes in one of the
/// `ChatExportFormat`s. Pure (no SwiftUI, no disk writes) so it's unit-testable;
/// the app layer hands the resulting `ChatExportBundle` to `.fileExporter`.
///
/// Human formats (markdown / plain text / docx) carry **prose + reasoning** —
/// user/assistant `.text` and `.reasoningSummary`, clearly labelled; tool
/// calls/results and embedded images/attachments are omitted. The **json**
/// format is the full `Conversation` Codable, so it re-imports losslessly.
public enum ChatExporter {
    /// Build a ready-to-write bundle for the given conversations and format.
    ///
    /// - json: always a single combined array (re-importable), one file.
    /// - markdown / plainText / docx: a single bare file for one conversation,
    ///   or a `.zip` with one file per conversation for several.
    public static func export(
        _ conversations: [Conversation],
        as format: ChatExportFormat
    ) throws -> ChatExportBundle {
        guard !conversations.isEmpty else { throw ChatExportError.nothingSelected }

        switch format {
        case .json:
            let data = try json(conversations)
            let name = conversations.count == 1
                ? "\(sanitizedFilename(conversations[0].title)).json"
                : "F-Chat export.json"
            return ChatExportBundle(data: data, suggestedFilename: name, contentType: format.contentType)

        case .markdown, .plainText, .docx:
            if conversations.count == 1 {
                let c = conversations[0]
                let data = try fileData(for: c, format: format)
                let name = "\(sanitizedFilename(c.title)).\(format.fileExtension)"
                return ChatExportBundle(data: data, suggestedFilename: name, contentType: format.contentType)
            } else {
                let data = try bundleZip(conversations, format: format)
                return ChatExportBundle(data: data, suggestedFilename: "F-Chat export.zip", contentType: .zip)
            }
        }
    }

    /// The bytes of a single conversation in a single (non-json) human format.
    static func fileData(for c: Conversation, format: ChatExportFormat) throws -> Data {
        switch format {
        case .markdown: return Data(markdown(c).utf8)
        case .plainText: return Data(plainText(c).utf8)
        case .docx: return try docx(c)
        case .json: return try json([c])
        }
    }

    // MARK: - JSON (lossless, re-importable)

    /// Encode conversations as the native F-Chat JSON array — same encoder
    /// config as persistence, so it round-trips through the importer's native
    /// path with full fidelity.
    public static func json(_ conversations: [Conversation]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(conversations)
        } catch {
            throw ChatExportError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Transcript model (shared by md / txt / docx)

    /// One turn worth of exportable content: the role label plus the prose and
    /// (optional) reasoning, in order. Empty turns are dropped by the caller.
    private struct Turn {
        var roleLabel: String
        var timestamp: Date
        /// (isReasoning, text) segments in display order.
        var segments: [(isReasoning: Bool, text: String)]
    }

    /// Extract the human-readable turns from a conversation: user/assistant
    /// messages with their `.text` and `.reasoningSummary` content. Messages
    /// with neither (only tool/image content) are skipped.
    private static func turns(of c: Conversation) -> [Turn] {
        c.messages.compactMap { m -> Turn? in
            // Only conversational roles appear in a transcript.
            let label: String
            switch m.role {
            case .user: label = "You"
            case .assistant: label = "Assistant"
            case .system, .tool: return nil
            }
            var segments: [(isReasoning: Bool, text: String)] = []
            for item in m.contentItems {
                switch item {
                case .text(let s) where !s.isEmpty:
                    segments.append((false, s))
                case .reasoningSummary(let s) where !s.isEmpty:
                    segments.append((true, s))
                default:
                    continue  // tool calls/results, images, attachments — omitted
                }
            }
            guard !segments.isEmpty else { return nil }
            return Turn(roleLabel: label, timestamp: m.createdAt, segments: segments)
        }
    }

    private static func timestampString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Markdown

    public static func markdown(_ c: Conversation) -> String {
        var out = "# \(c.title)\n\n"
        for turn in turns(of: c) {
            out += "## \(turn.roleLabel)\n"
            out += "*\(timestampString(turn.timestamp))*\n\n"
            for seg in turn.segments {
                if seg.isReasoning {
                    // Reasoning as a labelled blockquote so it's visually set apart.
                    out += "> **Reasoning**\n"
                    for line in seg.text.split(separator: "\n", omittingEmptySubsequences: false) {
                        out += "> \(line)\n"
                    }
                    out += "\n"
                } else {
                    out += "\(seg.text)\n\n"
                }
            }
        }
        // Trim trailing whitespace/newlines to a single terminal newline.
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Plain text

    public static func plainText(_ c: Conversation) -> String {
        var out = "\(c.title)\n\(String(repeating: "=", count: max(3, c.title.count)))\n\n"
        for turn in turns(of: c) {
            out += "\(turn.roleLabel.uppercased())  (\(timestampString(turn.timestamp)))\n"
            for seg in turn.segments {
                if seg.isReasoning {
                    out += "[Reasoning]\n\(seg.text)\n"
                } else {
                    out += "\(seg.text)\n"
                }
            }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Word (.docx)

    public static func docx(_ c: Conversation) throws -> Data {
        var paragraphs: [DocxWriter.Paragraph] = []
        paragraphs.append(DocxWriter.Paragraph([DocxWriter.Run(text: c.title, bold: true)]))
        paragraphs.append(.blank)
        for turn in turns(of: c) {
            paragraphs.append(DocxWriter.Paragraph([DocxWriter.Run(text: turn.roleLabel, bold: true)]))
            paragraphs.append(DocxWriter.Paragraph([
                DocxWriter.Run(text: timestampString(turn.timestamp), italic: true)
            ]))
            for seg in turn.segments {
                if seg.isReasoning {
                    paragraphs.append(DocxWriter.Paragraph([DocxWriter.Run(text: "Reasoning", italic: true)]))
                }
                paragraphs.append(.plain(seg.text))
            }
            paragraphs.append(.blank)
        }
        return try DocxWriter.build(paragraphs: paragraphs)
    }

    // MARK: - Zip bundle (one file per chat)

    /// Pack one file per conversation into an in-memory `.zip`, named from each
    /// chat's sanitised title (collisions deduped with a numeric suffix).
    static func bundleZip(_ conversations: [Conversation], format: ChatExportFormat) throws -> Data {
        do {
            guard let archive = try? Archive(accessMode: .create) else {
                throw ChatExportError.zipFailed("could not create archive")
            }
            var used = Set<String>()
            for c in conversations {
                let base = uniqueName(sanitizedFilename(c.title), used: &used)
                let entryName = "\(base).\(format.fileExtension)"
                let bytes = try fileData(for: c, format: format)
                try archive.addEntry(
                    with: entryName,
                    type: .file,
                    uncompressedSize: Int64(bytes.count),
                    compressionMethod: .deflate,
                    provider: { position, size in
                        let start = Int(position)
                        return bytes.subdata(in: start ..< start + size)
                    }
                )
            }
            guard let data = archive.data else {
                throw ChatExportError.zipFailed("archive produced no data")
            }
            return data
        } catch let error as ChatExportError {
            throw error
        } catch {
            throw ChatExportError.zipFailed(error.localizedDescription)
        }
    }

    // MARK: - Filenames

    /// Turn a chat title into a safe filename component: strip path/illegal
    /// characters, collapse whitespace, trim, cap length, and never return empty.
    public static func sanitizedFilename(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var cleaned = title.components(separatedBy: illegal).joined(separator: " ")
        cleaned = cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Avoid leading dots (hidden files) and over-long names.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// Ensure a base name is unique within `used`, appending " 2", " 3", … on
    /// collision (case-insensitively, since filesystems often fold case).
    private static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var n = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(base) \(n)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}

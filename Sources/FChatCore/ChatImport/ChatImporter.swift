// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import ZIPFoundation

/// Front door for importing third-party chat exports. Detects whether a payload
/// is a ChatGPT or Claude `conversations.json`, dispatches to the right parser,
/// and (for `.zip` inputs) locates the JSON inside the archive first.
public enum ChatImporter {
    /// Parse a file the user picked. Accepts either a `.zip` data export or a
    /// raw `conversations.json`. Throws `ChatImportError` on unrecognised or
    /// empty input.
    public static func parse(fileURL: URL) throws -> ChatImportResult {
        let ext = fileURL.pathExtension.lowercased()
        let jsonData: Data
        if ext == "zip" {
            jsonData = try conversationsJSON(fromZip: fileURL)
        } else {
            do {
                jsonData = try Data(contentsOf: fileURL)
            } catch {
                throw ChatImportError.notValidJSON(error.localizedDescription)
            }
        }
        return try parse(jsonData: jsonData)
    }

    /// Parse already-loaded JSON bytes (the `conversations.json` contents).
    public static func parse(jsonData: Data) throws -> ChatImportResult {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            throw ChatImportError.notValidJSON(error.localizedDescription)
        }

        // An empty top-level array is a valid-but-empty export, not an
        // unrecognised format.
        if let arr = json as? [Any], arr.isEmpty {
            throw ChatImportError.emptyExport
        }

        let format: ChatImportFormat
        let chats: [ImportedChat]
        if NativeImporter.looksLikeFChat(json) {
            format = .fchat
            chats = try NativeImporter.parse(jsonData)
        } else if ChatGPTImporter.looksLikeChatGPT(json) {
            format = .chatGPT
            chats = try ChatGPTImporter.parse(jsonData)
        } else if ClaudeImporter.looksLikeClaude(json) {
            format = .claude
            chats = try ClaudeImporter.parse(jsonData)
        } else {
            throw ChatImportError.unrecognizedFormat
        }

        guard !chats.isEmpty else { throw ChatImportError.emptyExport }

        // Surface conversations the parser skipped (malformed / empty) as a
        // single non-fatal warning so the user knows the count may differ.
        let total = topLevelCount(json)
        var warnings: [String] = []
        if total > chats.count {
            warnings.append("\(total - chats.count) conversation(s) were skipped because they had no readable messages.")
        }
        return ChatImportResult(format: format, chats: chats, warnings: warnings)
    }

    /// How many conversation objects the export contained at the top level —
    /// an array's count, or 1 for a single-conversation object. Used to detect
    /// skipped (unreadable) conversations for the warning.
    private static func topLevelCount(_ json: Any) -> Int {
        if let array = json as? [Any] { return array.count }
        if json is [String: Any] { return 1 }
        return 0
    }

    // MARK: - Zip

    /// Locate and read `conversations.json` from a data-export `.zip`. The file
    /// is usually at the archive root but some exports nest it one level down,
    /// so we match by filename anywhere in the archive.
    static func conversationsJSON(fromZip url: URL) throws -> Data {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ChatImportError.zipUnreadable(error.localizedDescription)
        }
        // Prefer an exact root-level `conversations.json`, else the first entry
        // whose filename is conversations.json at any depth.
        let entry = archive["conversations.json"]
            ?? archive.first(where: {
                URL(fileURLWithPath: $0.path).lastPathComponent == "conversations.json"
                    && !$0.path.contains("__MACOSX")
            })
        guard let entry else { throw ChatImportError.zipMissingConversations }
        var data = Data()
        do {
            _ = try archive.extract(entry) { data.append($0) }
        } catch {
            throw ChatImportError.zipUnreadable(error.localizedDescription)
        }
        return data
    }
}

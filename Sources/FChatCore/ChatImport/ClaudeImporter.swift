// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Parses an Anthropic/Claude data export `conversations.json`.
///
/// The export is a JSON array of conversations, each with a `uuid`, `name`
/// (title), `created_at`/`updated_at` (ISO-8601), and a flat `chat_messages`
/// array. Each message has `sender` ("human"/"assistant"), a `created_at`, and
/// its text either in a top-level `text` string or (newer exports) a `content`
/// array of typed blocks. We prefer the structured `content` blocks and fall
/// back to `text`.
public enum ClaudeImporter {
    public static func parse(_ data: Data) throws -> [ImportedChat] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ChatImportError.notValidJSON(error.localizedDescription)
        }
        guard let array = root as? [[String: Any]] else {
            throw ChatImportError.unrecognizedFormat
        }
        var chats: [ImportedChat] = []
        for convo in array {
            if let chat = parseConversation(convo) { chats.append(chat) }
        }
        return chats
    }

    /// True if a decoded JSON value looks like a Claude export (array of objects
    /// carrying a `chat_messages` array). Used by the format detector.
    static func looksLikeClaude(_ json: Any) -> Bool {
        guard let array = json as? [[String: Any]], let first = array.first else { return false }
        return first["chat_messages"] is [Any]
    }

    private static func parseConversation(_ convo: [String: Any]) -> ImportedChat? {
        guard let rawMessages = convo["chat_messages"] as? [[String: Any]] else { return nil }

        let title = (convo["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let created = isoDate(convo["created_at"]) ?? .distantPast
        let updated = isoDate(convo["updated_at"]) ?? created
        let model = (convo["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var messages: [ImportedMessage] = []
        for msg in rawMessages {
            if let imported = importedMessage(from: msg) { messages.append(imported) }
        }
        guard !messages.isEmpty else { return nil }
        return ImportedChat(title: title, createdAt: created, updatedAt: updated, model: model, messages: messages)
    }

    private static func importedMessage(from msg: [String: Any]) -> ImportedMessage? {
        guard let sender = msg["sender"] as? String else { return nil }
        let role: ImportedMessage.Role
        switch sender {
        case "human": role = .user
        case "assistant": role = .assistant
        default: return nil
        }

        // Prefer the structured `content` blocks; fall back to the flat `text`.
        var text = textFromContentBlocks(msg["content"]) ?? (msg["text"] as? String) ?? ""
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let created = isoDate(msg["created_at"]) ?? .distantPast
        return ImportedMessage(role: role, text: text, createdAt: created)
    }

    /// Concatenate the `text` of `type == "text"` blocks in a Claude message's
    /// `content` array. Returns nil when there's no usable content array (so the
    /// caller falls back to the legacy `text` field).
    private static func textFromContentBlocks(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            let t = block["text"] as? String
            return (t?.isEmpty ?? true) ? nil : t
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    /// Claude timestamps are ISO-8601 strings (e.g. "2024-05-01T12:34:56Z" or
    /// with fractional seconds). Try the fractional variant first.
    /// (Formatters are built per call — `ISO8601DateFormatter` isn't `Sendable`,
    /// and import is not a hot path.)
    static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

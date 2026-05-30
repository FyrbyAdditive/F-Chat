// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Re-imports F-Chat's own native JSON export (an array of `Conversation`
/// objects). This closes the export→import loop: a `.json` produced by
/// `ChatExporter` round-trips back into native conversations. Because the
/// payload is exactly the persisted `Conversation` shape, we decode it straight
/// with `JSONDecoder` and flatten to the neutral `ImportedChat` the app layer
/// already knows how to commit.
enum NativeImporter {
    /// Does this JSON look like an F-Chat export? An array whose elements carry
    /// both `settings` and a `messages` array of objects with `contentItems` —
    /// the native shape, distinct from ChatGPT (`mapping`) and Claude
    /// (`chat_messages`).
    static func looksLikeFChat(_ json: Any) -> Bool {
        guard let array = json as? [[String: Any]], let first = array.first else { return false }
        guard first["settings"] is [String: Any] else { return false }
        guard let messages = first["messages"] as? [[String: Any]] else {
            // A conversation with no messages is still valid F-Chat JSON.
            return first["messages"] is [Any]
        }
        // If there are messages, the native ones carry `contentItems`.
        return messages.first?["contentItems"] != nil || messages.isEmpty
    }

    static func parse(_ data: Data) throws -> [ImportedChat] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conversations: [Conversation]
        do {
            conversations = try decoder.decode([Conversation].self, from: data)
        } catch {
            throw ChatImportError.notValidJSON(error.localizedDescription)
        }
        return conversations.compactMap(importedChat)
    }

    /// Flatten a native `Conversation` to an `ImportedChat`, keeping prose and
    /// reasoning per message (the same content the human exports carry). Drops
    /// conversations with no readable user/assistant text.
    private static func importedChat(_ c: Conversation) -> ImportedChat? {
        let messages: [ImportedMessage] = c.messages.compactMap { m in
            let role: ImportedMessage.Role
            switch m.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system, .tool: return nil
            }
            var text = ""
            var reasoning = ""
            for item in m.contentItems {
                switch item {
                case .text(let s): text += (text.isEmpty ? "" : "\n") + s
                case .reasoningSummary(let s): reasoning += (reasoning.isEmpty ? "" : "\n") + s
                default: continue
                }
            }
            guard !text.isEmpty || !reasoning.isEmpty else { return nil }
            return ImportedMessage(
                role: role,
                text: text,
                reasoning: reasoning.isEmpty ? nil : reasoning,
                createdAt: m.createdAt
            )
        }
        guard !messages.isEmpty else { return nil }
        return ImportedChat(
            title: c.title,
            createdAt: c.createdAt,
            updatedAt: c.updatedAt,
            model: c.settings.model.isEmpty ? nil : c.settings.model,
            messages: messages
        )
    }
}

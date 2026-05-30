// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Parses an OpenAI/ChatGPT data export `conversations.json`.
///
/// The export is a JSON array of conversations. Each conversation stores its
/// messages as a `mapping` — a dict of nodes `{ id, parent, children, message }`
/// forming a tree (branches appear when the user edited a message and
/// regenerated). To reconstruct the conversation the user actually sees, we
/// walk from `current_node` up the `parent` chain to the root and reverse it;
/// that selects the latest/active branch and ignores edited-away siblings. When
/// `current_node` is absent we fall back to the deepest leaf by message
/// `create_time`.
public enum ChatGPTImporter {
    public static func parse(_ data: Data) throws -> [ImportedChat] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ChatImportError.notValidJSON(error.localizedDescription)
        }
        // Accept either the full export (a top-level array of conversations) or
        // a single-conversation export (one conversation object, as produced by
        // browser extensions / the share-link API). Both use the same per-chat
        // `mapping` shape.
        let conversations = conversationObjects(from: root)
        guard !conversations.isEmpty else { throw ChatImportError.unrecognizedFormat }
        var chats: [ImportedChat] = []
        for convo in conversations {
            if let chat = parseConversation(convo) { chats.append(chat) }
        }
        return chats
    }

    /// Normalise the decoded JSON to a list of conversation objects, whether the
    /// top level is an array (full export) or a single conversation object
    /// (single-chat export). Returns empty when it's neither.
    private static func conversationObjects(from json: Any) -> [[String: Any]] {
        if let array = json as? [[String: Any]] { return array }
        if let object = json as? [String: Any], object["mapping"] is [String: Any] { return [object] }
        return []
    }

    /// True if a decoded JSON value looks like a ChatGPT export — either an
    /// array of objects carrying a `mapping`, or a single conversation object
    /// with a `mapping`. Used by the format detector.
    static func looksLikeChatGPT(_ json: Any) -> Bool {
        if let array = json as? [[String: Any]], let first = array.first {
            return first["mapping"] is [String: Any]
        }
        if let object = json as? [String: Any] {
            return object["mapping"] is [String: Any]
        }
        return false
    }

    // MARK: - Per-conversation

    private static func parseConversation(_ convo: [String: Any]) -> ImportedChat? {
        guard let mapping = convo["mapping"] as? [String: Any] else { return nil }

        let title = (convo["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let created = epochDate(convo["create_time"]) ?? .distantPast
        let updated = epochDate(convo["update_time"]) ?? created

        // Build a node lookup of just the entries that have a usable shape.
        var nodes: [String: Node] = [:]
        for (id, raw) in mapping {
            guard let dict = raw as? [String: Any] else { continue }
            nodes[id] = Node(
                id: id,
                parent: dict["parent"] as? String,
                children: dict["children"] as? [String] ?? [],
                message: dict["message"] as? [String: Any]
            )
        }
        guard !nodes.isEmpty else { return nil }

        let orderedIDs = linearPath(currentNode: convo["current_node"] as? String, nodes: nodes)

        var messages: [ImportedMessage] = []
        var model: String?
        for id in orderedIDs {
            guard let node = nodes[id], let msg = node.message else { continue }
            if let m = modelSlug(from: msg), model == nil { model = m }
            guard let imported = importedMessage(from: msg) else { continue }
            messages.append(imported)
        }
        guard !messages.isEmpty else { return nil }
        return ImportedChat(title: title, createdAt: created, updatedAt: updated, model: model, messages: messages)
    }

    private struct Node {
        let id: String
        let parent: String?
        let children: [String]
        let message: [String: Any]?
    }

    /// The ordered list of node ids along the active branch, root→leaf.
    private static func linearPath(currentNode: String?, nodes: [String: Node]) -> [String] {
        // Preferred: walk up from current_node to the root via parent links.
        if let leaf = currentNode, nodes[leaf] != nil {
            var chain: [String] = []
            var cursor: String? = leaf
            var guardCount = 0
            while let id = cursor, let node = nodes[id], guardCount < nodes.count + 1 {
                chain.append(id)
                cursor = node.parent
                guardCount += 1
            }
            return chain.reversed()
        }
        // Fallback: find a root (no parent / parent missing), then always
        // descend into the child with the latest message create_time — i.e.
        // the most recently used branch.
        guard let rootID = nodes.values.first(where: { $0.parent == nil || nodes[$0.parent!] == nil })?.id
                ?? nodes.keys.first
        else { return [] }
        var path: [String] = []
        var cursor: String? = rootID
        var guardCount = 0
        while let id = cursor, let node = nodes[id], guardCount < nodes.count + 1 {
            path.append(id)
            // Pick the child whose message create_time is greatest (latest
            // branch); ties or missing times fall back to the last child.
            let kids = node.children.compactMap { nodes[$0] }
            cursor = kids.max(by: { createTime($0.message) < createTime($1.message) })?.id ?? node.children.last
            guardCount += 1
        }
        return path
    }

    private static func createTime(_ message: [String: Any]?) -> Double {
        guard let message else { return -.greatestFiniteMagnitude }
        return (message["create_time"] as? Double) ?? -.greatestFiniteMagnitude
    }

    // MARK: - Message mapping

    private static func importedMessage(from msg: [String: Any]) -> ImportedMessage? {
        // Skip nodes hidden from the visible conversation (tool/system plumbing).
        if let meta = msg["metadata"] as? [String: Any],
           (meta["is_visually_hidden_from_conversation"] as? Bool) == true {
            return nil
        }
        guard let author = msg["author"] as? [String: Any],
              let roleString = author["role"] as? String else { return nil }

        let role: ImportedMessage.Role
        switch roleString {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil   // system / tool — dropped
        }

        guard let content = msg["content"] as? [String: Any] else { return nil }
        let contentType = content["content_type"] as? String ?? "text"

        var text = ""
        var reasoning: String?
        switch contentType {
        case "text", "multimodal_text", "code", "execution_output":
            text = joinParts(content["parts"])
        case "thoughts":
            // Reasoning models export chain-of-thought here; surface it as a
            // reasoning summary rather than body text.
            reasoning = joinThoughts(content["thoughts"]) ?? joinParts(content["parts"])
            text = ""
        case "reasoning_recap":
            reasoning = content["content"] as? String ?? joinParts(content["parts"])
            text = ""
        default:
            text = joinParts(content["parts"])
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep messages that have visible text OR reasoning; drop pure-empty.
        if trimmed.isEmpty && (reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return nil
        }
        let created = epochDate(msg["create_time"]) ?? .distantPast
        return ImportedMessage(role: role, text: trimmed, reasoning: reasoning, createdAt: created)
    }

    /// `content.parts` is an array of strings and/or objects (image pointers,
    /// audio, etc.). Keep the string parts; objects with a `text` field
    /// contribute their text; everything else is ignored (best-effort).
    private static func joinParts(_ parts: Any?) -> String {
        guard let parts = parts as? [Any] else { return "" }
        var pieces: [String] = []
        for part in parts {
            if let s = part as? String {
                if !s.isEmpty { pieces.append(s) }
            } else if let obj = part as? [String: Any], let t = obj["text"] as? String, !t.isEmpty {
                pieces.append(t)
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    private static func joinThoughts(_ thoughts: Any?) -> String? {
        guard let arr = thoughts as? [[String: Any]] else { return nil }
        let pieces = arr.compactMap { th -> String? in
            let summary = th["summary"] as? String
            let content = th["content"] as? String
            return [summary, content].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }.filter { !$0.isEmpty }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
    }

    private static func modelSlug(from msg: [String: Any]) -> String? {
        guard let meta = msg["metadata"] as? [String: Any],
              let slug = meta["model_slug"] as? String, !slug.isEmpty else { return nil }
        return slug
    }

    /// ChatGPT timestamps are Unix epoch *seconds* as a Double (sometimes
    /// fractional). May be null on placeholder nodes.
    static func epochDate(_ value: Any?) -> Date? {
        guard let seconds = value as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

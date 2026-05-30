// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Provider-neutral intermediate produced by the per-provider importers
/// (ChatGPT, Claude). The app layer turns each `ImportedChat` into a native
/// `Conversation` + `Message`s, assigning a provider/model at import time.
public struct ImportedChat: Sendable, Hashable {
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Exported model name when the source provides one (e.g. "gpt-4o",
    /// "claude-3-5-sonnet-20241022"); nil → caller falls back to a default.
    public var model: String?
    public var messages: [ImportedMessage]

    public init(
        title: String,
        createdAt: Date,
        updatedAt: Date,
        model: String? = nil,
        messages: [ImportedMessage]
    ) {
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.messages = messages
    }
}

public struct ImportedMessage: Sendable, Hashable {
    public enum Role: Sendable, Hashable { case user, assistant }

    public var role: Role
    /// The message's visible text (markdown preserved). May be empty only when
    /// the message carries attachments/images instead.
    public var text: String
    /// Reasoning / chain-of-thought text the source exposed separately
    /// (ChatGPT "thoughts"); rendered as a reasoning summary, not body text.
    public var reasoning: String?
    public var createdAt: Date

    public init(role: Role, text: String, reasoning: String? = nil, createdAt: Date) {
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.createdAt = createdAt
    }
}

/// Which export a payload was recognised as.
public enum ChatImportFormat: String, Sendable, Hashable {
    case chatGPT = "ChatGPT"
    case claude = "Claude"
    /// F-Chat's own native JSON export (round-trips losslessly).
    case fchat = "F-Chat"
}

/// Outcome of parsing an export: the recognised format, the chats, and any
/// non-fatal warnings (e.g. individual conversations skipped because they were
/// malformed, or attachments that couldn't be resolved).
public struct ChatImportResult: Sendable {
    public var format: ChatImportFormat
    public var chats: [ImportedChat]
    public var warnings: [String]

    public init(format: ChatImportFormat, chats: [ImportedChat], warnings: [String] = []) {
        self.format = format
        self.chats = chats
        self.warnings = warnings
    }

    public var messageCount: Int { chats.reduce(0) { $0 + $1.messages.count } }
}

public enum ChatImportError: Error, CustomStringConvertible, Equatable {
    case unrecognizedFormat
    case emptyExport
    case notValidJSON(String)
    case zipMissingConversations
    case zipUnreadable(String)

    public var description: String {
        switch self {
        case .unrecognizedFormat:
            return "This file isn't a recognised ChatGPT or Claude export. Pick the conversations.json (or the .zip) from your data export."
        case .emptyExport:
            return "The export didn't contain any conversations."
        case .notValidJSON(let detail):
            return "The file isn't valid JSON: \(detail)"
        case .zipMissingConversations:
            return "The .zip doesn't contain a conversations.json file."
        case .zipUnreadable(let detail):
            return "Could not read the .zip: \(detail)"
        }
    }
}

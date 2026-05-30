// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public struct Conversation: Identifiable, Sendable, Hashable, Codable {
    public let id: ConversationID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var settings: ChatSettings
    public var messages: [Message]
    public var previousResponseID: String?
    /// Per-chat reasoning effort knob. Exposed via the composer's tiny menu
    /// (not provider settings) because users typically want to flip between
    /// quick replies and deeper reasoning on a per-turn / per-chat basis.
    /// `nil` means "use server default".
    public var reasoningEffort: ReasoningEffort?
    /// Records of past compactions for the transcript UI. Each entry
    /// stores the index range of messages that were summarized away in
    /// the sent payload (the messages stay in `messages` for the UI).
    public var compactions: [CompactionRecord]
    /// Cached "context size at the moment we sent this message". Drives
    /// the per-message context footer. Keyed by message id.
    public var contextTokensByMessage: [MessageID: Int]

    public init(
        id: ConversationID = .init(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        settings: ChatSettings,
        messages: [Message] = [],
        previousResponseID: String? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        compactions: [CompactionRecord] = [],
        contextTokensByMessage: [MessageID: Int] = [:]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.settings = settings
        self.messages = messages
        self.previousResponseID = previousResponseID
        self.reasoningEffort = reasoningEffort
        self.compactions = compactions
        self.contextTokensByMessage = contextTokensByMessage
    }

    // Custom Decodable so older state.json files without newer fields
    // load cleanly (missing optionals / arrays / dicts decode to defaults).
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, settings, messages
        case previousResponseID, reasoningEffort, compactions, contextTokensByMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(ConversationID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.settings = try c.decode(ChatSettings.self, forKey: .settings)
        self.messages = try c.decode([Message].self, forKey: .messages)
        self.previousResponseID = try c.decodeIfPresent(String.self, forKey: .previousResponseID)
        self.reasoningEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        self.compactions = try c.decodeIfPresent([CompactionRecord].self, forKey: .compactions) ?? []
        self.contextTokensByMessage = try c.decodeIfPresent([MessageID: Int].self, forKey: .contextTokensByMessage) ?? [:]
    }
}

/// A single past compaction. The message indices reference into
/// `Conversation.messages` at the time the compaction ran. They stay valid
/// as long as we only ever append new messages to a conversation, which is
/// the case today.
public struct CompactionRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// Inclusive lower bound, exclusive upper bound: messages[from..<to] were
    /// summarized away in the sent payload.
    public var fromIndex: Int
    public var toIndex: Int
    public var summary: String
    public var compactedAt: Date

    public init(id: UUID = UUID(), fromIndex: Int, toIndex: Int, summary: String, compactedAt: Date = .now) {
        self.id = id
        self.fromIndex = fromIndex
        self.toIndex = toIndex
        self.summary = summary
        self.compactedAt = compactedAt
    }

    public var messageCount: Int { max(0, toIndex - fromIndex) }
}

public struct Message: Identifiable, Sendable, Hashable, Codable {
    public let id: MessageID
    public var role: MessageRole
    public var contentItems: [MessageContent]
    public var usage: UsageInfo?
    public var createdAt: Date
    public var responseID: String?
    /// Wall-clock seconds from the first streamed delta to the moment the
    /// response ended (or `usage` was reported). Used to compute tokens/sec
    /// for display.
    public var generationDuration: TimeInterval?

    public init(
        id: MessageID = .init(),
        role: MessageRole,
        contentItems: [MessageContent],
        usage: UsageInfo? = nil,
        createdAt: Date = .now,
        responseID: String? = nil,
        generationDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.role = role
        self.contentItems = contentItems
        self.usage = usage
        self.createdAt = createdAt
        self.responseID = responseID
        self.generationDuration = generationDuration
    }

    public var tokensPerSecond: Double? {
        guard let usage, let duration = generationDuration, duration > 0 else { return nil }
        return Double(usage.outputTokens) / duration
    }

    public var plainText: String {
        contentItems.compactMap { item -> String? in
            if case .text(let s) = item { return s }
            return nil
        }.joined(separator: "\n")
    }
}

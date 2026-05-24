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

    public init(
        id: ConversationID = .init(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        settings: ChatSettings,
        messages: [Message] = [],
        previousResponseID: String? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.settings = settings
        self.messages = messages
        self.previousResponseID = previousResponseID
        self.reasoningEffort = reasoningEffort
    }

    // Custom Decodable so older state.json files without `reasoningEffort`
    // load cleanly (missing optional decodes to nil).
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, settings, messages, previousResponseID, reasoningEffort
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
    }
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

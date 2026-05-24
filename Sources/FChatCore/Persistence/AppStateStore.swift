import Foundation

/// Atomically writes and reads a JSON-encoded snapshot of the user's state
/// (providers, conversations, language, etc.) to `Application Support/F-Chat`.
///
/// We deliberately avoid SwiftData here. The state is small, the value types
/// are already `Codable`, and a single JSON file gives us trivial backup,
/// inspection (`cat state.json | jq`), and zero schema-migration overhead.
public struct AppStateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let dir = base.appendingPathComponent("F-Chat", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("state.json")
        }
    }

    public func load() -> PersistedAppState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedAppState.self, from: data)
    }

    public func save(_ state: PersistedAppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// The snapshot we persist. Versioned so future schema bumps can branch on it.
public struct PersistedAppState: Codable, Sendable {
    public var version: Int
    public var providers: [ProviderRecord]
    public var conversations: [Conversation]
    public var selectedConversationID: ConversationID?
    public var promptLanguage: PromptLanguage
    /// Global active provider for new chats. Optional so older state files
    /// load cleanly; resolved to `providers.first?.id` at runtime when nil.
    public var activeProviderID: ProviderID?
    /// Tool names the user has enabled globally. Optional/missing on older
    /// state files; treated as "all built-ins enabled" when absent so the
    /// behaviour matches what existing chats have been getting.
    public var enabledTools: Set<String>?

    public init(
        version: Int = 3,
        providers: [ProviderRecord],
        conversations: [Conversation],
        selectedConversationID: ConversationID?,
        promptLanguage: PromptLanguage,
        activeProviderID: ProviderID? = nil,
        enabledTools: Set<String>? = nil
    ) {
        self.version = version
        self.providers = providers
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
        self.promptLanguage = promptLanguage
        self.activeProviderID = activeProviderID
        self.enabledTools = enabledTools
    }
}

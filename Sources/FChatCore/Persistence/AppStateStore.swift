// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

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
        self.fileURL = fileURL ?? AppDataDirectories.ensureRoot().appendingPathComponent("state.json")
    }

    public func load() -> PersistedAppState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedAppState.self, from: data)
    }

    public func save(_ state: PersistedAppState) throws {
        let encoder = JSONEncoder()
        // .sortedKeys roughly doubles encode cost on a 70k-token state by
        // sorting every key in the nested tree. Dropped — the file stays
        // human-readable with .prettyPrinted alone.
        encoder.outputFormatting = [.prettyPrinted]
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
    /// Named system-prompt presets ("agents"). Optional/missing on older
    /// state files; AppEnvironment seeds the built-in Default when absent
    /// so behaviour for pre-feature chats matches today.
    public var agents: [Agent]?
    /// Which agent newly-created chats start out using. Optional/missing
    /// on older state files; resolves to `AgentID.defaultAgent` at runtime.
    public var defaultAgentForNewChats: AgentID?
    /// User-configured MCP servers. Optional/missing on older state files;
    /// resolves to an empty list at runtime. Per-server `enabled` flag
    /// gates whether the registry connects to it on first use.
    public var mcpServers: [MCPServerRecord]?
    /// Installed Agent Skills (the global library). Optional/missing on older
    /// state files; resolves to an empty list at runtime. The skills' bundled
    /// files live on disk under the SkillStore directory keyed by id — only
    /// the parsed metadata + instruction body persist here.
    public var skills: [Skill]?

    public init(
        version: Int = 4,
        providers: [ProviderRecord],
        conversations: [Conversation],
        selectedConversationID: ConversationID?,
        promptLanguage: PromptLanguage,
        activeProviderID: ProviderID? = nil,
        enabledTools: Set<String>? = nil,
        agents: [Agent]? = nil,
        defaultAgentForNewChats: AgentID? = nil,
        mcpServers: [MCPServerRecord]? = nil,
        skills: [Skill]? = nil
    ) {
        self.version = version
        self.providers = providers
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
        self.promptLanguage = promptLanguage
        self.activeProviderID = activeProviderID
        self.enabledTools = enabledTools
        self.agents = agents
        self.defaultAgentForNewChats = defaultAgentForNewChats
        self.mcpServers = mcpServers
        self.skills = skills
    }
}

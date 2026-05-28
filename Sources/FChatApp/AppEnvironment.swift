import Foundation
import SwiftUI
import FChatCore
import FChatProviders
import FChatTools
import FChatWeb
import FChatRAG
import FChatMCP

/// Owns the long-lived services the UI binds against. A single instance is
/// created at app start and injected into the environment.
@MainActor
@Observable
final class AppEnvironment {
    let secretStore: any SecretStore
    let toolRegistry: ToolRegistry
    let collectionStore: any CollectionStoreProtocol
    /// Per-conversation view models, cached by id. Created lazily on first
    /// visit and kept for the rest of the session so an in-flight reply
    /// survives a sidebar navigation — Stop is the only thing that cancels.
    /// Concurrent streams on different chats are isolated via
    /// `ChatTaskContext` (a `@TaskLocal` for the per-turn attached RAG
    /// collections, set by ChatViewModel.send for the lifetime of the
    /// stream task).
    var chatViewModels: [ConversationID: ChatViewModel] = [:]
    /// Lazy-built ingest queue shared across the Collections UI so per-file
    /// progress survives pane switches.
    var ingestQueue: IngestQueue?
    let ingestor: FileIngestor
    let pageExtractor: any PageExtractor
    /// In-process LRU of web_fetch results so a re-fetch of the same URL
    /// in the same session skips both the network and the (full-body)
    /// token cost.
    let webFetchCache: WebFetchCache
    let searchProvider: any WebSearchProvider
    let stateStore: AppStateStore
    var providerRecords: [ProviderRecord] {
        didSet { scheduleSave() }
    }
    var conversations: [Conversation] {
        didSet { scheduleSave() }
    }
    var selectedConversationID: ConversationID? {
        didSet { scheduleSave() }
    }
    var promptLanguage: PromptLanguage {
        didSet { scheduleSave() }
    }
    /// Global active provider. All chats use this provider; switching it
    /// reroutes every chat to the new provider on the next send.
    var activeProviderID: ProviderID? {
        didSet { scheduleSave() }
    }
    /// Built-in tool names enabled globally. Disabled tools are filtered out
    /// of the `tools` array sent to the LLM at request time.
    var enabledTools: Set<String> {
        didSet { scheduleSave() }
    }
    /// Named system-prompt presets ("agents"). Always non-empty in
    /// practice because `init` seeds the built-in Default agent on first
    /// launch and recreates it if the persisted list is missing it.
    var agents: [Agent] {
        didSet { scheduleSave() }
    }
    /// Which agent newly-created chats start with. nil resolves to
    /// `AgentID.defaultAgent`.
    var defaultAgentForNewChats: AgentID? {
        didSet { scheduleSave() }
    }
    /// User-configured MCP servers. Per-record `enabled` gates whether
    /// the registry will connect to it; the connection itself is lazy
    /// (triggered by the first chat send after launch via
    /// `mcpRegistry.ensureLoaded(servers:)`).
    var mcpServers: [MCPServerRecord] {
        didSet { scheduleSave() }
    }
    /// Session-scoped MCP connections + their registered tool adapters.
    /// Constructed once in `init`, idempotent `ensureLoaded` walks the
    /// `mcpServers` list on first chat send.
    let mcpRegistry: MCPRegistry
    /// OAuth coordinator surfaced on AppEnvironment so the Settings UI
    /// can drive sign-in / sign-out for HTTP MCP servers without
    /// reaching into the registry.
    let oauthCoordinator: OAuthCoordinator
    var sidebarSelection: SidebarSelection?

    /// Global on-by-default tool toggles surfaced in Settings → Tools.
    /// `rag_search` is NOT listed here: it's always available (gated
    /// per-chat by the Inspector's Collections section instead), and is
    /// admitted unconditionally by the request-build filter regardless
    /// of what's in `enabledTools`.
    static let defaultEnabledTools: Set<String> = ["web_search", "web_fetch"]

    /// Tools that bypass the user-facing on/off toggle in Settings →
    /// Tools and are always advertised to the model. `rag_search` lives
    /// here because users gate it per-chat via the Inspector's
    /// Collections section: when no collection is attached, the tool
    /// has nothing to retrieve anyway, so a global off-switch is
    /// redundant noise.
    static let alwaysAvailableTools: Set<String> = ["rag_search"]

    /// Cached `/models` results per provider, keyed by ProviderID.
    var detectedModels: [ProviderID: [ModelInfo]] = [:]
    var providerStatus: [ProviderID: ProviderConnectionStatus] = [:]

    private var saveTask: Task<Void, Never>?

    init() {
        self.secretStore = KeychainStore()
        self.toolRegistry = ToolRegistry()
        // Persistent SQLite + sqlite-vec store. Falls back to the in-memory
        // store if the DB can't be opened (rare; would mean filesystem fail).
        let resolvedStore: any CollectionStoreProtocol
        do {
            let db = try RAGDatabase.openDefault()
            resolvedStore = PersistentCollectionStore(
                database: db,
                embedderFactory: { kind, _, _ in
                    // On-device path goes through MLX + Qwen3-Embedding-4B.
                    // The shared container loads the ~2.26 GB weights once
                    // per session and serves every MLX-backed collection.
                    // Remote path falls back to the legacy OpenAI-compatible
                    // RemoteEmbedder (instantiated elsewhere — kept for the
                    // .openAICompatible kind once we wire the picker UI).
                    switch kind {
                    case .mlxQwen3Embedding4B:
                        let container = try await MLXEmbedderLoader.shared.shared()
                        return MLXQwen3Embedder(container: container)
                    case .openAICompatible:
                        throw EmbedderError.unavailable("Remote embeddings: pick an OpenAI-compatible provider explicitly when creating the collection.")
                    case .test:
                        return HashEmbedder()
                    }
                }
            )
        } catch {
            FileHandle.standardError.write(Data("[FChat] rag database open failed (\(error)); falling back to in-memory store\n".utf8))
            resolvedStore = CollectionStore()
        }
        self.collectionStore = resolvedStore
        let pageExtractor = WebKitPageExtractor()
        self.pageExtractor = pageExtractor
        self.ingestor = FileIngestor(pageExtractor: pageExtractor)
        self.webFetchCache = WebFetchCache()
        self.searchProvider = DuckDuckGoProvider()
        self.stateStore = AppStateStore()
        // Restore from disk if present; otherwise fall back to defaults.
        if let snapshot = self.stateStore.load() {
            self.providerRecords = snapshot.providers.isEmpty ? AppEnvironment.defaultProviders() : snapshot.providers
            self.conversations = snapshot.conversations
            self.selectedConversationID = snapshot.selectedConversationID
            self.promptLanguage = snapshot.promptLanguage
            self.activeProviderID = snapshot.activeProviderID
            self.enabledTools = snapshot.enabledTools ?? AppEnvironment.defaultEnabledTools
            self.agents = AppEnvironment.ensureDefaultAgent(in: snapshot.agents ?? [])
            self.defaultAgentForNewChats = snapshot.defaultAgentForNewChats
            self.mcpServers = snapshot.mcpServers ?? []
        } else {
            self.providerRecords = AppEnvironment.defaultProviders()
            self.conversations = []
            self.selectedConversationID = nil
            self.promptLanguage = PromptLanguage.resolve()
            self.activeProviderID = nil
            self.enabledTools = AppEnvironment.defaultEnabledTools
            self.agents = AppEnvironment.ensureDefaultAgent(in: [])
            self.defaultAgentForNewChats = nil
            self.mcpServers = []
        }
        // OAuth coordinator owns interactive sign-in + token refresh
        // for HTTP MCP servers with `useOAuth = true`. Passed into the
        // registry so its .http connect path can mint Authorization
        // bearer tokens before constructing the transport.
        let oauth = OAuthCoordinator(secretStore: self.secretStore)
        self.oauthCoordinator = oauth
        // Session-scoped registry; lazy-connects via ensureLoaded on
        // first chat send. Holding the toolRegistry lets it
        // dynamically register/unregister MCPToolAdapter instances.
        self.mcpRegistry = MCPRegistry(toolRegistry: self.toolRegistry, oauthCoordinator: oauth)
        // Resolve the active provider id if it's stale (deleted) or missing.
        if let active = self.activeProviderID, !self.providerRecords.contains(where: { $0.id == active }) {
            self.activeProviderID = self.providerRecords.first?.id
        }
        if self.activeProviderID == nil {
            self.activeProviderID = self.providerRecords.first?.id
        }
        if let id = self.selectedConversationID, self.conversations.contains(where: { $0.id == id }) {
            self.sidebarSelection = .conversation(id)
        } else {
            self.sidebarSelection = nil
        }
    }

    /// Coalesces writes so that a burst of changes (e.g. streaming chunks
    /// updating a conversation message-by-message) results in at most one
    /// disk write every ~400ms.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.persistNow()
        }
    }

    func persistNow() {
        let snapshot = PersistedAppState(
            providers: providerRecords,
            conversations: conversations,
            selectedConversationID: selectedConversationID,
            promptLanguage: promptLanguage,
            activeProviderID: activeProviderID,
            enabledTools: enabledTools,
            agents: agents,
            defaultAgentForNewChats: defaultAgentForNewChats,
            mcpServers: mcpServers
        )
        // Encode + atomic write off MainActor. At 70k+ tokens the encode
        // alone is hundreds of ms — running it on MainActor blocked the UI
        // at the end of every streaming reply (one save fires after the
        // 400ms debounce drains). PersistedAppState is value-typed and
        // AppStateStore is Sendable, so detaching is safe; the atomic
        // write is filesystem-atomic so back-to-back saves can't corrupt.
        let store = stateStore
        Task.detached(priority: .utility) {
            do {
                try store.save(snapshot)
            } catch {
                FileHandle.standardError.write(Data("[FChat] persist failed: \(error)\n".utf8))
            }
        }
    }

    /// The provider new conversations should be created with. Falls back to
    /// the first configured provider when no global active id is set.
    func currentProvider() -> ProviderRecord? {
        if let id = activeProviderID, let record = provider(id) { return record }
        return providerRecords.first
    }

    func provider(_ id: ProviderID) -> ProviderRecord? {
        providerRecords.first(where: { $0.id == id })
    }

    func makeRuntimeProvider(for record: ProviderRecord) -> any LLMProvider {
        OpenAIResponsesProvider(
            id: record.id,
            baseURL: record.baseURL,
            session: .shared,
            secretStore: secretStore
        )
    }

    func refreshModels(for record: ProviderRecord) async {
        providerStatus[record.id] = .checking
        let runtime = makeRuntimeProvider(for: record)
        do {
            let models = try await runtime.listModels()
            let sorted = models.sorted { $0.id < $1.id }
            detectedModels[record.id] = sorted
            providerStatus[record.id] = .ok(modelCount: sorted.count, checkedAt: .now)
            // Backfill any conversations bound to this provider that have a model id
            // the server doesn't actually expose — common immediately after launch when
            // newConversation runs before detection completes.
            backfillConversationModels(providerID: record.id, detected: sorted)
        } catch {
            detectedModels[record.id] = []
            providerStatus[record.id] = .failed(message: error.localizedDescription, checkedAt: .now)
        }
    }

    private func backfillConversationModels(providerID: ProviderID, detected: [ModelInfo]) {
        guard let first = detected.first else { return }
        let validIDs = Set(detected.map(\.id))
        for index in conversations.indices where conversations[index].settings.providerID == providerID {
            let current = conversations[index].settings.model
            if current.isEmpty || !validIDs.contains(current) {
                conversations[index].settings.model = first.id
            }
        }
    }

    func updateProvider(_ updated: ProviderRecord) {
        if let i = providerRecords.firstIndex(where: { $0.id == updated.id }) {
            providerRecords[i] = updated
        }
    }

    func addProvider(displayName: String, baseURL: URL) -> ProviderRecord {
        let id = ProviderID(rawValue: slug(from: displayName.isEmpty ? baseURL.host ?? "provider" : displayName))
        let record = ProviderRecord(id: id, displayName: displayName.isEmpty ? id.rawValue : displayName, baseURL: baseURL)
        providerRecords.append(record)
        // If this is the first provider, make it the active default.
        if activeProviderID == nil {
            activeProviderID = id
        }
        return record
    }

    func removeProvider(_ id: ProviderID) {
        providerRecords.removeAll { $0.id == id }
        detectedModels[id] = nil
        providerStatus[id] = nil
        // If we just removed the active provider, fall back to whatever's left.
        if activeProviderID == id {
            activeProviderID = providerRecords.first?.id
        }
    }

    func registerBuiltInTools() async {
        let webSearch = WebSearchTool(provider: searchProvider)
        let webFetch = WebFetchTool(extractor: pageExtractor, cache: webFetchCache)
        let rag = RAGSearchTool(retriever: DynamicAttachedRAGRetriever(
            store: collectionStore,
            // TaskLocal scoped per stream turn — set by ChatViewModel.send
            // and propagated into every tool-call subtask the runner spawns.
            // Lets two chats stream concurrently without their rag_search
            // calls clobbering each other's attached collections.
            attachedAccessor: { ChatTaskContext.attachedCollections }
        ))
        // current_time is opt-in (not in defaultEnabledTools) so the system
        // prompt prefix stays cache-friendly for users who don't need
        // sub-day time precision. They enable it via Settings → Tools.
        let currentTime = CurrentTimeTool()
        // make_chart is also opt-in: charts are useful but most chats don't
        // need them, and an unconditionally-advertised chart tool nudges
        // the model toward producing visual output when the user just
        // wanted prose.
        let makeChart = MakeChartTool()
        await toolRegistry.register(webSearch)
        await toolRegistry.register(webFetch)
        await toolRegistry.register(rag)
        await toolRegistry.register(currentTime)
        await toolRegistry.register(makeChart)
    }

    static func defaultProviders() -> [ProviderRecord] {
        [
            ProviderRecord(
                id: ProviderID(rawValue: "fyrby-magi"),
                displayName: "Fyrby Magi (dev)",
                baseURL: URL(string: "https://magi.fyrby.internal:8000/v1")!,
                defaultModel: nil
            )
        ]
    }

    // MARK: - Agents

    /// Guarantees the built-in Default agent is present in the list, at
    /// the front. If the persisted list already has a Default entry it's
    /// preserved as-is — including any user edits to `basePrompt` (which
    /// the Settings → Agents UI allows). Only when Default is missing
    /// entirely do we seed a fresh one with nil basePrompt (resolves to
    /// the localised built-in preamble at compose time).
    static func ensureDefaultAgent(in existing: [Agent]) -> [Agent] {
        if let i = existing.firstIndex(where: { $0.id == .defaultAgent }) {
            if i == 0 { return existing }
            // Move to front without losing user state.
            var list = existing
            let entry = list.remove(at: i)
            list.insert(entry, at: 0)
            return list
        }
        var list = existing
        let seeded = Agent(
            id: .defaultAgent,
            name: String(localized: "Default", bundle: .module),
            basePrompt: nil
        )
        list.insert(seeded, at: 0)
        return list
    }

    /// Look up the agent a chat should be using. Falls back to the
    /// built-in Default when the chat's `agentID` is nil, missing, or
    /// pointing at a deleted agent. Never returns a synthetic value if
    /// the agents list is correctly seeded; the last fallback exists
    /// only as a defensive escape hatch.
    func resolveAgent(for conversation: Conversation) -> Agent {
        let target = conversation.settings.agentID
            ?? defaultAgentForNewChats
            ?? .defaultAgent
        return agents.first(where: { $0.id == target })
            ?? agents.first(where: { $0.id == .defaultAgent })
            ?? Agent.builtInDefault
    }

    @discardableResult
    func addAgent(name: String, basePrompt: String?) -> Agent {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = basePrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = Agent(
            id: AgentID(),
            name: trimmedName.isEmpty ? String(localized: "Untitled agent", bundle: .module) : trimmedName,
            basePrompt: (trimmedPrompt?.isEmpty ?? true) ? nil : trimmedPrompt
        )
        agents.append(agent)
        return agent
    }

    /// Updates an agent in place. The Default agent is editable too — the
    /// user can override its preamble or revert to the localised built-in
    /// by setting `basePrompt = nil`. Default's name cannot be changed
    /// (the UI doesn't expose a name field for it).
    func updateAgent(_ updated: Agent) {
        guard let i = agents.firstIndex(where: { $0.id == updated.id }) else { return }
        var copy = updated
        // Default's display name stays whatever the seed put there;
        // ignore any name change attempts so a future rename UI added
        // here can't accidentally make the Default unrecognisable.
        if updated.id == .defaultAgent {
            copy.name = agents[i].name
        }
        copy.updatedAt = .now
        agents[i] = copy
    }

    func deleteAgent(_ id: AgentID) {
        guard id != .defaultAgent else { return }
        agents.removeAll { $0.id == id }
        if defaultAgentForNewChats == id {
            defaultAgentForNewChats = nil
        }
        // Chats that referenced this agent keep their stale agentID — the
        // resolver silently falls back to Default. We deliberately don't
        // sweep `conversations` here so the persisted intent survives if
        // the agent is later re-added (e.g. via state-file restore).
    }

    /// Count of chats currently referencing this agent. Drives the delete
    /// confirmation copy ("N chats will fall back to Default").
    func chatCountUsingAgent(_ id: AgentID) -> Int {
        conversations.reduce(0) { $0 + ((($1.settings.agentID ?? .defaultAgent) == id) ? 1 : 0) }
    }

    // MARK: - MCP servers

    @discardableResult
    func addMCPServer(displayName: String, transport: MCPTransportConfig) -> MCPServerRecord {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = MCPServerRecord(
            id: MCPServerID(rawValue: UUID().uuidString),
            displayName: trimmed.isEmpty ? String(localized: "Untitled server", bundle: .module) : trimmed,
            transport: transport,
            enabled: true
        )
        mcpServers.append(record)
        // If a chat has already triggered an ensureLoaded this session
        // we'd otherwise skip the new server until next launch. Connect
        // it eagerly so adding a server in Settings "just works".
        if record.enabled {
            Task { await mcpRegistry.connect(record) }
        }
        return record
    }

    func updateMCPServer(_ updated: MCPServerRecord) {
        guard let i = mcpServers.firstIndex(where: { $0.id == updated.id }) else { return }
        let previous = mcpServers[i]
        mcpServers[i] = updated
        // Config changed? Force a reconnect so the running client
        // doesn't carry stale subprocess / URL state.
        if previous.transport != updated.transport || previous.enabled != updated.enabled {
            Task { await mcpRegistry.reconnect(updated) }
        }
    }

    func setMCPServerEnabled(_ id: MCPServerID, enabled: Bool) {
        guard let i = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        guard mcpServers[i].enabled != enabled else { return }
        mcpServers[i].enabled = enabled
        let record = mcpServers[i]
        if enabled {
            Task { await mcpRegistry.connect(record) }
        } else {
            Task { await mcpRegistry.disconnect(id) }
        }
    }

    func removeMCPServer(_ id: MCPServerID) {
        mcpServers.removeAll { $0.id == id }
        Task {
            await mcpRegistry.disconnect(id)
            // Drop any persisted OAuth state too — a re-add of the
            // same id (unlikely; ids are UUIDs) wouldn't want to inherit
            // stale tokens.
            await oauthCoordinator.clearTokens(for: id)
        }
    }

    /// Trigger interactive OAuth sign-in for an HTTP MCP server. The
    /// Settings UI calls this from the "Sign in" / "Re-authenticate"
    /// button. On success, also reconnects the registry so tools land
    /// without the user clicking Test connection separately.
    func signInToMCPServer(_ id: MCPServerID) async throws {
        guard let record = mcpServers.first(where: { $0.id == id }) else { return }
        guard case .http(let httpConfig) = record.transport else { return }
        do {
            try await oauthCoordinator.reauthorize(
                serverID: id,
                resource: httpConfig.url,
                httpConfig: httpConfig
            )
        } catch {
            // Surface the failure in the always-visible card header too,
            // not just the form's inline error line, then rethrow so the
            // button's catch can render the detail.
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            mcpRegistry.setFailedStatus(id, reason: reason)
            throw error
        }
        await mcpRegistry.connect(record)
    }

    /// Clear any persisted OAuth tokens for this server and disconnect
    /// it. The card stays in the list; the user can sign in again later.
    func signOutOfMCPServer(_ id: MCPServerID) async {
        await mcpRegistry.disconnect(id)
        await oauthCoordinator.clearTokens(for: id)
    }

    func newConversation(title: String) {
        guard let provider = currentProvider() else { return }
        let model = provider.defaultModel
            ?? detectedModels[provider.id]?.first?.id
            ?? ""
        let settings = ChatSettings(
            model: model,
            providerID: provider.id,
            enabledBuiltInTools: ["web_search", "web_fetch"]
        )
        let conversation = Conversation(title: title, settings: settings)
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        sidebarSelection = .conversation(conversation.id)
        // Kick off model detection so the chat can be used immediately.
        if detectedModels[provider.id] == nil {
            Task { await refreshModels(for: provider) }
        }
    }

    func conversation(_ id: ConversationID) -> Conversation? {
        conversations.first(where: { $0.id == id })
    }

    /// Returns the live `ChatViewModel` for the conversation, creating and
    /// caching one on first access. View models survive sidebar navigation
    /// — switching chats does NOT tear them down — so an in-flight stream
    /// continues running while the user looks at something else. Only an
    /// explicit cancel (Stop button) or deletion ends a stream. Returns
    /// nil if the conversation has been deleted.
    func viewModel(for id: ConversationID) -> ChatViewModel? {
        if let existing = chatViewModels[id] { return existing }
        guard let conversation = self.conversation(id) else { return nil }
        let vm = ChatViewModel(conversation: conversation, environment: self)
        chatViewModels[id] = vm
        return vm
    }

    func update(_ conversation: Conversation) {
        if let i = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[i] = conversation
        }
    }

    func deleteConversation(_ id: ConversationID) {
        // Cancel any in-flight stream for this chat and free its cached
        // view model before dropping the underlying conversation.
        chatViewModels[id]?.cancel()
        chatViewModels.removeValue(forKey: id)
        let wasSelected = (selectedConversationID == id)
        conversations.removeAll { $0.id == id }
        if wasSelected {
            // Select the next nearest conversation, or land on the empty placeholder.
            if let next = conversations.first {
                selectedConversationID = next.id
                sidebarSelection = .conversation(next.id)
            } else {
                selectedConversationID = nil
                sidebarSelection = nil
            }
        }
    }

    func deleteAllConversations() {
        for (_, vm) in chatViewModels { vm.cancel() }
        chatViewModels.removeAll()
        conversations.removeAll()
        selectedConversationID = nil
        sidebarSelection = nil
    }

    private func slug(from text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let lower = text.lowercased()
        var out = ""
        var lastDash = false
        for ch in lower {
            if allowed.contains(ch) {
                out.append(ch)
                lastDash = (ch == "-")
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "provider-\(UUID().uuidString.prefix(6))" : trimmed
    }
}

enum ProviderConnectionStatus: Sendable {
    case unknown
    case checking
    case ok(modelCount: Int, checkedAt: Date)
    case failed(message: String, checkedAt: Date)
}

enum SidebarSelection: Hashable {
    case conversation(ConversationID)
    case settings
    case collections
}

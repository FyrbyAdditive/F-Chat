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
    /// Set by `ChatViewModel.send` immediately before kicking off a stream
    /// so the rag_search tool can default to "all attached collections for
    /// the active chat" when the model omits the `collection` argument.
    var attachedCollectionsForActiveChat: [CollectionID] = []
    /// Lazy-built ingest queue shared across the Collections UI so per-file
    /// progress survives pane switches.
    var ingestQueue: IngestQueue?
    let ingestor: FileIngestor
    let pageExtractor: any PageExtractor
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
    var sidebarSelection: SidebarSelection?

    static let defaultEnabledTools: Set<String> = ["web_search", "web_fetch", "rag_search"]

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
                embedderFactory: { _, _, _ in
                    // Apple on-device contextual embeddings (Latin script
                    // covers English + Swedish + most western European).
                    switch AppleEmbedderLoader.loadLatin() {
                    case .ready(let e): return e
                    case .unavailable(let reason):
                        throw EmbedderError.unavailable(reason)
                    }
                }
            )
        } catch {
            FileHandle.standardError.write(Data("[FChat] rag database open failed (\(error)); falling back to in-memory store\n".utf8))
            resolvedStore = CollectionStore()
        }
        self.collectionStore = resolvedStore
        self.ingestor = FileIngestor()
        self.pageExtractor = WebKitPageExtractor()
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
        } else {
            self.providerRecords = AppEnvironment.defaultProviders()
            self.conversations = []
            self.selectedConversationID = nil
            self.promptLanguage = PromptLanguage.resolve()
            self.activeProviderID = nil
            self.enabledTools = AppEnvironment.defaultEnabledTools
        }
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
            enabledTools: enabledTools
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
        let webFetch = WebFetchTool(extractor: pageExtractor)
        let rag = RAGSearchTool(retriever: DynamicAttachedRAGRetriever(
            store: collectionStore,
            attachedAccessor: { [weak self] in
                guard let self else { return [] }
                return self.attachedCollectionsForActiveChat
            }
        ))
        await toolRegistry.register(webSearch)
        await toolRegistry.register(webFetch)
        await toolRegistry.register(rag)
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

    func newConversation(title: String) {
        guard let provider = currentProvider() else { return }
        let model = provider.defaultModel
            ?? detectedModels[provider.id]?.first?.id
            ?? ""
        let settings = ChatSettings(
            model: model,
            providerID: provider.id,
            enabledBuiltInTools: ["web_search", "web_fetch", "rag_search"]
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

    func update(_ conversation: Conversation) {
        if let i = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[i] = conversation
        }
    }

    func deleteConversation(_ id: ConversationID) {
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

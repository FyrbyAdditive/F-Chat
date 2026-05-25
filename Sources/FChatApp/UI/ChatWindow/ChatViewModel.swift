import Foundation
import Observation
import FChatCore
import FChatProviders
import FChatTools

@MainActor
@Observable
final class ChatViewModel {
    var conversation: Conversation {
        didSet {
            environment?.update(conversation)
            scheduleProjectionRefresh()
        }
    }
    var draftText: String = "" {
        didSet { scheduleProjectionRefresh() }
    }
    var isStreaming: Bool = false
    /// Per-conversation transient error attached to whichever user message
    /// it relates to. Cleared on retry.
    var lastError: String?
    /// MessageID of the failed user message we should offer a Retry button on.
    var failedUserMessageID: MessageID?
    /// Live projection of the next send. Drives the meter chip.
    var projection: RequestPayloadBuilder.Projection?
    /// Effective budget for the currently active provider/model. Drives
    /// the meter's denominator.
    var budget: ContextBudget?
    /// True while we're running a summarize call as part of compact-then-send.
    var isCompacting: Bool = false

    private weak var environment: AppEnvironment?
    private var streamTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private var firstDeltaAt: Date?
    /// Memoises per-message token counts so a streaming-induced projection
    /// re-run only tokenises the message whose content actually changed
    /// (always the tail). Without this, every ~150ms debounce tick during a
    /// long reply re-tokenises the whole transcript on the main actor.
    private let tokenCountCache = MessageTokenCountCache()

    init(conversation: Conversation, environment: AppEnvironment) {
        self.conversation = conversation
        self.environment = environment
        // Kick the first projection so the meter has a value at view open.
        Task { @MainActor in self.refreshProjectionNow() }
    }

    // MARK: - Projection

    private func scheduleProjectionRefresh() {
        projectionTask?.cancel()
        projectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.refreshProjectionNow()
        }
    }

    func refreshProjectionNow() {
        guard let environment, let provider = environment.currentProvider() else {
            projection = nil
            budget = nil
            return
        }
        let modelID = provider.defaultModel ?? ""
        let modelInfo = environment.detectedModels[provider.id]?.first(where: { $0.id == modelID })
        let budget = ContextBudget.resolve(settings: provider.context, model: modelInfo)
        self.budget = budget

        let tokenizer = TokenizerCache.shared.get(modelID: modelID)
        let builder = RequestPayloadBuilder(tokenizer: tokenizer)
        let instructions = composeInstructions(language: environment.promptLanguage)
        let language = environment.promptLanguage
        let enabledToolNames = environment.enabledTools
        let registry = environment.toolRegistry

        // Snapshot the value-typed inputs and run the expensive BPE walk on a
        // detached task so it doesn't block the main actor during streaming.
        // Tool defs come from an actor and have to be fetched first.
        let conversationSnapshot = self.conversation
        let draftSnapshot = self.draftText
        let cache = self.tokenCountCache
        Task.detached(priority: .userInitiated) { [weak self] in
            let allDefs = await registry.definitions(for: language)
            let toolDefs = allDefs.filter { enabledToolNames.contains($0.name) }
            let projection = builder.project(
                conversation: conversationSnapshot,
                draftUserText: draftSnapshot,
                instructions: instructions,
                toolDefinitions: toolDefs,
                cache: cache
            )
            await MainActor.run {
                self?.projection = projection
            }
        }
    }

    private func composeInstructions(language: PromptLanguage) -> String {
        let prompt = LocalizedSystemPrompt(
            language: language,
            includeToolGuidance: true,
            includeRAGGuidance: !conversation.settings.attachedCollections.isEmpty
        )
        let temporal = TemporalContext(language: language).render()
        return prompt.render() + "\n\n" + temporal
    }

    // MARK: - Send

    func send() {
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let environment else { return }
        guard let providerRecord = environment.currentProvider() else {
            lastError = "No provider configured. Open Settings → Providers."
            return
        }
        let trimmedModel = (providerRecord.defaultModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            lastError = "No default model set for provider \(providerRecord.displayName). Open Settings → Providers and pick one."
            return
        }

        let userText = draftText
        draftText = ""
        lastError = nil
        failedUserMessageID = nil

        let userMessage = Message(role: .user, contentItems: [.text(userText)])
        conversation.messages.append(userMessage)
        conversation.updatedAt = .now
        let userMessageID = userMessage.id

        // Oversized-single-message check — refuse to send if the user
        // message alone exceeds the budget. Their text stays in the
        // composer (we already cleared draftText; restore it).
        let modelInfo = environment.detectedModels[providerRecord.id]?.first(where: { $0.id == trimmedModel })
        let budget = ContextBudget.resolve(settings: providerRecord.context, model: modelInfo)
        let tokenizer = TokenizerCache.shared.get(modelID: trimmedModel)
        let userMessageTokens = tokenizer.countTokens(in: userText)
        if userMessageTokens > budget.effectiveWindow {
            // Roll back the queued user message.
            conversation.messages.removeAll { $0.id == userMessageID }
            draftText = userText
            lastError = "Your message is \(userMessageTokens.formatted()) tokens — larger than this provider's \(budget.effectiveWindow.formatted())-token window. Save it as a RAG document instead (coming soon)."
            return
        }

        let assistantMessage = Message(role: .assistant, contentItems: [])
        conversation.messages.append(assistantMessage)
        let assistantIndex = conversation.messages.count - 1
        let assistantMessageID = assistantMessage.id

        let registry = environment.toolRegistry
        let promptLanguage = environment.promptLanguage
        let llm = environment.makeRuntimeProvider(for: providerRecord)
        let runner = ChatTurnRunner(provider: llm, registry: registry, maxIterations: providerRecord.sampling.maxToolIterations)

        // Publish this chat's attached collections to the environment so
        // the shared rag_search tool (registered once at startup) can fall
        // back to searching them when the model omits the `collection` arg.
        environment.attachedCollectionsForActiveChat = Array(conversation.settings.attachedCollections)

        isStreaming = true
        firstDeltaAt = nil
        let enabledTools = environment.enabledTools
        streamTask = Task { [weak self, assistantIndex] in
            guard let self else { return }
            do {
                let allDefinitions = await registry.definitions(for: promptLanguage)
                let toolDefinitions = allDefinitions.filter { enabledTools.contains($0.name) }

                let request = try await self.buildRequestWithCompactIfNeeded(
                    providerRecord: providerRecord,
                    modelID: trimmedModel,
                    language: promptLanguage,
                    toolDefinitions: toolDefinitions,
                    llm: llm,
                    budget: budget,
                    userMessageTokens: userMessageTokens,
                    userMessageID: userMessageID,
                    assistantMessageID: assistantMessageID
                )
                for try await event in runner.run(initial: request) {
                    await self.apply(event: event, assistantIndex: assistantIndex)
                }
            } catch {
                let rendered = ChatViewModel.describe(error: error)
                FileHandle.standardError.write(Data("[FChat] chat turn failed: \(rendered) — raw: \(error)\n".utf8))
                self.lastError = rendered
                self.failedUserMessageID = userMessageID
                // Drop the empty assistant placeholder we appended; the user
                // shouldn't see a blank assistant card next to a failed turn.
                self.conversation.messages.removeAll { $0.id == assistantMessageID }
            }
            self.isStreaming = false
            self.environment?.update(self.conversation)
            self.refreshProjectionNow()
        }
    }

    func cancel() {
        streamTask?.cancel()
        isStreaming = false
        isCompacting = false
    }

    /// Re-send the most recent user message after a failure. Removes the
    /// error UI immediately; if it fails again, the error returns.
    func retryLastFailedMessage() {
        guard let failedID = failedUserMessageID,
              let index = conversation.messages.lastIndex(where: { $0.id == failedID }),
              case .text(let text) = conversation.messages[index].contentItems.first
        else { return }
        // Remove the failed user message; send() will re-append it with the
        // same text, this time hopefully succeeding.
        conversation.messages.remove(at: index)
        lastError = nil
        failedUserMessageID = nil
        draftText = text
        send()
    }

    /// Manual "Compact now" action — runs the same flow as auto-compact
    /// but with the threshold check skipped.
    func compactNow() {
        guard let environment, let provider = environment.currentProvider() else { return }
        let modelID = (provider.defaultModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { return }
        let llm = environment.makeRuntimeProvider(for: provider)
        let language = environment.promptLanguage
        isCompacting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCompacting = false }
            do {
                let planner = CompactionPlanner()
                let plan = planner.plan(
                    messageCount: self.conversation.messages.count,
                    recentKeepCount: provider.context.recentKeepCount
                )
                guard plan.willCompact else { return }
                let summarizer = ConversationSummarizer(provider: llm, modelID: modelID, language: language)
                let slice = self.conversation.messages[plan.summarizeIndices]
                let summary = try await summarizer.summarize(messages: slice)
                let record = CompactionRecord(
                    fromIndex: plan.summarizeIndices.lowerBound,
                    toIndex: plan.summarizeIndices.upperBound,
                    summary: summary
                )
                self.conversation.compactions.append(record)
                self.refreshProjectionNow()
            } catch {
                self.lastError = ChatViewModel.describe(error: error)
            }
        }
    }

    // MARK: - Build request + maybe compact

    /// Builds the request payload, running compaction first if the
    /// projection crosses the threshold.
    private func buildRequestWithCompactIfNeeded(
        providerRecord: ProviderRecord,
        modelID: String,
        language: PromptLanguage,
        toolDefinitions: [ToolDefinition],
        llm: any LLMProvider,
        budget: ContextBudget,
        userMessageTokens: Int,
        userMessageID: MessageID,
        assistantMessageID: MessageID
    ) async throws -> ChatRequest {
        let tokenizer = TokenizerCache.shared.get(modelID: modelID)
        let builder = RequestPayloadBuilder(tokenizer: tokenizer)
        let instructions = composeInstructions(language: language)

        // Determine the active compaction state: keep range starts after the
        // most recent compaction's upper bound, if any.
        let firstKeepableIndex = conversation.compactions.last?.toIndex ?? 0
        let currentMessageCount = conversation.messages.count

        // Project the cost without any further compaction.
        let projection = builder.project(
            conversation: conversation,
            draftUserText: "",
            instructions: instructions,
            toolDefinitions: toolDefinitions,
            summary: existingSummariesConcatenated(),
            keepRange: firstKeepableIndex..<currentMessageCount
        )

        let projectedTotal = projection.totalTokens
        let needsCompact = projectedTotal >= budget.compactionTrigger

        var summary = existingSummariesConcatenated()
        var keepLowerBound = firstKeepableIndex

        if needsCompact {
            await MainActor.run { self.isCompacting = true }
            defer { Task { @MainActor in self.isCompacting = false } }

            let messagesAvailableToCompact = currentMessageCount - firstKeepableIndex
            let recentKeep = providerRecord.context.recentKeepCount
            // Keep recentKeep messages verbatim, including the new user/assistant
            // pair we just appended (which together count as 2 messages).
            // So we want to summarize everything from firstKeepableIndex up to
            // currentMessageCount - recentKeep.
            let pivotOffset = max(0, messagesAvailableToCompact - recentKeep)
            guard pivotOffset > 0 else {
                // Already at-or-under the keep window — nothing to do.
                let request = makeChatRequest(
                    modelID: modelID,
                    sampling: providerRecord.sampling,
                    instructions: instructions,
                    inputs: builder.assemble(
                        conversation: conversation,
                        draftUserText: "",
                        summary: summary,
                        keepRange: firstKeepableIndex..<currentMessageCount
                    ),
                    tools: toolDefinitions
                )
                await cacheContextSize(messageID: userMessageID, tokens: projectedTotal)
                _ = assistantMessageID
                return request
            }

            let summarizeFrom = firstKeepableIndex
            let summarizeTo = firstKeepableIndex + pivotOffset
            let summarizer = ConversationSummarizer(provider: llm, modelID: modelID, language: language)
            let slice = conversation.messages[summarizeFrom..<summarizeTo]
            let freshSummary = try await summarizer.summarize(messages: slice)

            let record = CompactionRecord(
                fromIndex: summarizeFrom,
                toIndex: summarizeTo,
                summary: freshSummary
            )
            await MainActor.run {
                self.conversation.compactions.append(record)
            }

            // Now compose the combined summary (existing + fresh) and shift
            // the keep range to after the new compaction.
            summary = existingSummariesConcatenated(plus: freshSummary)
            keepLowerBound = summarizeTo
        }

        let inputs = builder.assemble(
            conversation: conversation,
            draftUserText: "",
            summary: summary,
            keepRange: keepLowerBound..<currentMessageCount
        )
        // Re-project with the now-current shape and cache for the footer.
        let finalProjection = builder.project(
            conversation: conversation,
            draftUserText: "",
            instructions: instructions,
            toolDefinitions: toolDefinitions,
            summary: summary,
            keepRange: keepLowerBound..<currentMessageCount
        )
        await cacheContextSize(messageID: userMessageID, tokens: finalProjection.totalTokens)
        _ = userMessageTokens
        _ = assistantMessageID
        return makeChatRequest(
            modelID: modelID,
            sampling: providerRecord.sampling,
            instructions: instructions,
            inputs: inputs,
            tools: toolDefinitions
        )
    }

    private func makeChatRequest(
        modelID: String,
        sampling: ProviderSamplingDefaults,
        instructions: String,
        inputs: [InputItem],
        tools: [ToolDefinition]
    ) -> ChatRequest {
        ChatRequest(
            model: modelID,
            input: inputs,
            instructions: instructions,
            previousResponseID: nil,
            temperature: sampling.temperature,
            topP: sampling.topP,
            maxOutputTokens: sampling.maxOutputTokens,
            reasoningEffort: conversation.reasoningEffort,
            parallelToolCalls: sampling.parallelToolCalls,
            tools: tools,
            toolChoice: .auto,
            store: false
        )
    }

    private func existingSummariesConcatenated(plus extra: String? = nil) -> String? {
        var parts = conversation.compactions.map { "(\($0.compactedAt.formatted(date: .omitted, time: .shortened))) \($0.summary)" }
        if let extra { parts.append(extra) }
        if parts.isEmpty { return nil }
        return parts.joined(separator: "\n\n")
    }

    private func cacheContextSize(messageID: MessageID, tokens: Int) async {
        await MainActor.run {
            self.conversation.contextTokensByMessage[messageID] = tokens
        }
    }

    // MARK: - Stream event handler

    static func describe(error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum, let child = mirror.children.first {
            let label = child.label ?? "\(error)"
            let value = "\(child.value)"
            return value.isEmpty || value == "()" ? label : "\(label): \(value)"
        }
        return "\(error)"
    }

    private func apply(event: ChatTurnEvent, assistantIndex: Int) async {
        guard conversation.messages.indices.contains(assistantIndex) else { return }
        var message = conversation.messages[assistantIndex]
        switch event {
        case .textDelta, .textCompleted, .reasoningSummaryDelta, .toolCallStarted, .toolCallReady:
            if firstDeltaAt == nil { firstDeltaAt = .now }
        default:
            break
        }
        switch event {
        case .responseStarted(let id):
            conversation.previousResponseID = id
            message.responseID = id
        case .textDelta(_, let delta):
            if case .text(let existing) = message.contentItems.last {
                message.contentItems[message.contentItems.count - 1] = .text(existing + delta)
            } else {
                let trimmedDelta = delta.replacingOccurrences(of: "^[\\s]+", with: "", options: .regularExpression)
                if !trimmedDelta.isEmpty {
                    message.contentItems.append(.text(trimmedDelta))
                }
            }
        case .textCompleted(_, let full):
            let trimmed = full.replacingOccurrences(of: "^[\\s]+", with: "", options: .regularExpression)
            if case .text = message.contentItems.last {
                message.contentItems[message.contentItems.count - 1] = .text(trimmed)
            } else {
                message.contentItems.append(.text(trimmed))
            }
        case .reasoningSummaryDelta(_, let delta):
            if case .reasoningSummary(let existing) = message.contentItems.last {
                message.contentItems[message.contentItems.count - 1] = .reasoningSummary(existing + delta)
            } else {
                message.contentItems.append(.reasoningSummary(delta))
            }
        case .toolCallStarted(let callID, let name):
            message.contentItems.append(.toolCall(ToolCallRecord(id: callID, name: name, argumentsJSON: "", status: .running)))
        case .toolCallArgumentsDelta(let callID, let delta):
            if let i = message.contentItems.lastIndex(where: { item in
                if case .toolCall(let rec) = item { return rec.id == callID }
                return false
            }) {
                if case .toolCall(var rec) = message.contentItems[i] {
                    rec = ToolCallRecord(id: rec.id, name: rec.name, argumentsJSON: rec.argumentsJSON + delta, status: rec.status)
                    message.contentItems[i] = .toolCall(rec)
                }
            }
        case .toolCallReady(let callID, let name, let arguments):
            if let i = message.contentItems.lastIndex(where: { item in
                if case .toolCall(let rec) = item { return rec.id == callID }
                return false
            }) {
                message.contentItems[i] = .toolCall(ToolCallRecord(id: callID, name: name, argumentsJSON: arguments, status: .running))
            } else {
                message.contentItems.append(.toolCall(ToolCallRecord(id: callID, name: name, argumentsJSON: arguments, status: .running)))
            }
        case .toolResult(let callID, let output):
            if let i = message.contentItems.lastIndex(where: { item in
                if case .toolCall(let rec) = item { return rec.id == callID }
                return false
            }), case .toolCall(let rec) = message.contentItems[i] {
                message.contentItems[i] = .toolCall(ToolCallRecord(
                    id: rec.id,
                    name: rec.name,
                    argumentsJSON: rec.argumentsJSON,
                    status: output.isError ? .failed : .succeeded
                ))
            }
            message.contentItems.append(.toolResult(ToolResultRecord(callID: callID, outputJSON: output.outputJSON, isError: output.isError, display: output.display)))
        case .usage(let usage):
            message.usage = usage
            if let start = firstDeltaAt {
                message.generationDuration = Date.now.timeIntervalSince(start)
            }
        case .completed, .maxIterationsReached:
            if message.generationDuration == nil, let start = firstDeltaAt {
                message.generationDuration = Date.now.timeIntervalSince(start)
            }
        }
        conversation.messages[assistantIndex] = message
        conversation.updatedAt = .now
    }
}

/// Main-actor-bound tokenizer cache. Filled asynchronously via `warm(_:)`;
/// `get(modelID:)` returns the cached tokenizer or a `HeuristicTokenizer`
/// fallback. Callers that want accurate counts kick off a warm at startup.
@MainActor
final class TokenizerCache {
    static let shared = TokenizerCache()
    private var cache: [String: any Tokenizer] = [:]
    private var inFlight: Set<String> = []

    /// Synchronous lookup. Returns the cached tokenizer if loaded, or a
    /// heuristic estimator otherwise (and kicks off a background load so
    /// next time we have the real one).
    func get(modelID: String) -> any Tokenizer {
        if let cached = cache[modelID] { return cached }
        warm(modelID: modelID)
        return HeuristicTokenizer()
    }

    /// Async load + cache. Safe to call repeatedly for the same id.
    func warm(modelID: String) {
        guard cache[modelID] == nil, !inFlight.contains(modelID) else { return }
        inFlight.insert(modelID)
        Task { @MainActor in
            let tokenizer = await TokenizerRegistry.shared.tokenizer(for: modelID)
            self.cache[modelID] = tokenizer
            self.inFlight.remove(modelID)
        }
    }
}

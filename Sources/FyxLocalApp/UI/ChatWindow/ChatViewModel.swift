// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Observation
import FyxLocalCore
import FyxLocalProviders
import FyxLocalTools

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
    /// Pending attachments staged in the composer for the next send (images for
    /// vision models, text files inlined for any model). Session-only; cleared
    /// on send. Drives the chip row in the composer.
    var draftAttachments: [PendingAttachment] = [] {
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
    /// True once the auto-titler has fired for this chat (success or not).
    /// Prevents the titler from running again on subsequent turns even if
    /// the user later renames the chat back to the default string.
    private var didAutoTitle: Bool = false

    init(conversation: Conversation, environment: AppEnvironment) {
        self.conversation = conversation
        self.environment = environment
        // Suppress auto-titling on chats loaded from disk: if the title is
        // already something other than the default, or the conversation
        // already has assistant content, the titler has already had its
        // chance (or the user manually set the name).
        let hasAssistantReply = conversation.messages.contains { $0.role == .assistant && !$0.contentItems.isEmpty }
        if conversation.title != "New chat" || hasAssistantReply {
            self.didAutoTitle = true
        }
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
        var enabledToolNames = environment.enabledTools
            .union(AppEnvironment.alwaysAvailableTools)
        // Admit run_code only when this chat has ≥1 enabled skill; otherwise
        // the tool isn't offered to the model at all.
        if !environment.resolveEnabledSkills(for: conversation).isEmpty {
            enabledToolNames.insert("run_code")
        }
        let registry = environment.toolRegistry

        // Snapshot the value-typed inputs and run the expensive BPE walk on a
        // detached task so it doesn't block the main actor during streaming.
        // Tool defs come from an actor and have to be fetched first.
        let conversationSnapshot = self.conversation
        let draftSnapshot = self.draftText
        let cache = self.tokenCountCache
        Task.detached(priority: .userInitiated) { [weak self] in
            let allDefs = await registry.definitions(for: language)
            // MCP-discovered tools (`mcp__<server>__<tool>`) are admitted
            // unconditionally; the global Settings → Tools page surfaces
            // only built-ins. Whether a particular MCP server's tools
            // are present at all is gated upstream by whether the
            // server is enabled in Settings → MCP.
            let toolDefs = allDefs.filter { def in
                enabledToolNames.contains(def.name) || def.name.hasPrefix("mcp__")
            }
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
        // Resolve the chat's agent (falls back to Default when nil or
        // pointing at a deleted agent). The agent's basePrompt — if any —
        // replaces the FyxLocal preamble; tool / RAG guidance is still
        // auto-appended below so custom agents keep working with tools
        // and attached collections.
        let agentBase = environment?.resolveAgent(for: conversation).basePrompt
        let skillSummaries = (environment?.resolveEnabledSkills(for: conversation) ?? [])
            .map { LocalizedSystemPrompt.SkillSummary(name: $0.name, description: $0.description) }
        let prompt = LocalizedSystemPrompt(
            language: language,
            includeToolGuidance: true,
            includeRAGGuidance: !conversation.settings.attachedCollections.isEmpty,
            basePromptOverride: agentBase,
            skills: skillSummaries
        )
        // No temporal context here: a fresh ISO timestamp in the system
        // prompt invalidates vLLM's prefix cache on every send. The date
        // is now injected as an invisible "[Today is ...]" header on the
        // most recent user message at wire-encoding time (day-bucketed,
        // so the prefix on prior user turns stays byte-stable across
        // re-sends). Sub-day precision is available via the opt-in
        // `current_time` tool.
        return prompt.render()
    }

    // MARK: - Send

    func send() {
        // Allow sending with attachments and no text (e.g. "describe this image").
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draftAttachments.isEmpty else { return }
        guard let environment else { return }
        guard let providerRecord = environment.currentProvider() else {
            lastError = String(localized: "No provider configured. Open Settings → Providers.")
            return
        }
        let trimmedModel = (providerRecord.defaultModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            lastError = String(
                localized: "No default model set for provider \(providerRecord.displayName). Open Settings → Providers and pick one."
            )
            return
        }

        let userText = draftText
        let attachments = draftAttachments
        draftText = ""
        draftAttachments = []
        lastError = nil
        failedUserMessageID = nil

        // Build the user message: attachments first (images as BlobStore-backed
        // .image content; text files inlined as filename-prefixed .text), then
        // the typed text. Text files are inlined because the wire input shape
        // has no first-class file part — the model just sees their contents.
        var contentItems: [MessageContent] = []
        for att in attachments {
            switch att.kind {
            case .image(let data, let mimeType):
                contentItems.append(.image(data: data, mimeType: mimeType))
            case .textFile(let contents):
                contentItems.append(.text("\(att.filename):\n\(contents)"))
            }
        }
        if !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentItems.append(.text(userText))
        }
        let userMessage = Message(role: .user, contentItems: contentItems)
        conversation.messages.append(userMessage)
        conversation.updatedAt = .now
        let userMessageID = userMessage.id

        // Oversized-single-message check — refuse to send if the user
        // message alone exceeds the budget. Count the typed text plus any
        // inlined text-file contents (images are counted by the builder).
        // On rejection, restore both the text and the attachments to the
        // composer (we already cleared them).
        let modelInfo = environment.detectedModels[providerRecord.id]?.first(where: { $0.id == trimmedModel })
        let budget = ContextBudget.resolve(settings: providerRecord.context, model: modelInfo)
        let tokenizer = TokenizerCache.shared.get(modelID: trimmedModel)
        let countedText = contentItems.reduce(into: "") { acc, item in
            if case .text(let t) = item { acc += t + "\n" }
        }
        let userMessageTokens = tokenizer.countTokens(in: countedText)
        if userMessageTokens > budget.effectiveWindow {
            // Roll back the queued user message and restore the composer.
            conversation.messages.removeAll { $0.id == userMessageID }
            draftText = userText
            draftAttachments = attachments
            lastError = String(
                localized: "Your message is \(userMessageTokens.formatted()) tokens — larger than this provider's \(budget.effectiveWindow.formatted())-token window. Save it as a RAG document instead (coming soon)."
            )
            return
        }

        let assistantMessage = Message(role: .assistant, contentItems: [])
        conversation.messages.append(assistantMessage)
        let assistantIndex = conversation.messages.count - 1
        let assistantMessageID = assistantMessage.id

        runAssistantTurn(
            providerRecord: providerRecord,
            trimmedModel: trimmedModel,
            budget: budget,
            assistantIndex: assistantIndex,
            assistantMessageID: assistantMessageID,
            failureMessageID: userMessageID
        )
    }

    /// Stream a single assistant turn into the placeholder at `assistantIndex`.
    /// Factored out of `send()` so both a fresh send and a *regenerate* (which
    /// appends no new user message) reuse the exact same compaction + tool +
    /// streaming machinery. `failureMessageID` is the message a Retry button
    /// attaches to if the turn fails — the just-sent user message for `send()`,
    /// or the prior user message for a regenerate.
    private func runAssistantTurn(
        providerRecord: ProviderRecord,
        trimmedModel: String,
        budget: ContextBudget,
        assistantIndex: Int,
        assistantMessageID: MessageID,
        failureMessageID: MessageID
    ) {
        guard let environment else { return }
        let registry = environment.toolRegistry
        let promptLanguage = environment.promptLanguage
        let llm = environment.makeRuntimeProvider(for: providerRecord)
        let runner = ChatTurnRunner(provider: llm, registry: registry, maxIterations: providerRecord.sampling.maxToolIterations)

        // Capture this chat's attached collections as a per-turn TaskLocal so
        // the shared rag_search tool (registered once at startup) can fall
        // back to searching them when the model omits the `collection` arg.
        // TaskLocal scoping means two chats streaming concurrently don't
        // clobber each other.
        let attachedCollections = Array(conversation.settings.attachedCollections)

        // Resolve this chat's enabled skills into (name, on-disk dir) refs for
        // the per-turn TaskLocal the shared run_code tool reads. Same isolation
        // story as attachedCollections — concurrent chats don't clobber.
        let enabledSkillRefs: [SkillRuntimeRef] = environment.resolveEnabledSkills(for: conversation).map {
            SkillRuntimeRef(name: $0.name, directory: environment.skillStore.skillRootDirectory(for: $0.id))
        }
        // Whether the calendar tool may stage write proposals this turn.
        let calendarWritesAllowed = environment.enabledTools.contains("calendar_write")
        // Whether the reminders tool may stage write proposals this turn.
        let reminderWritesAllowed = environment.enabledTools.contains("reminders_write")

        isStreaming = true
        firstDeltaAt = nil
        var enabledTools = environment.enabledTools
            .union(AppEnvironment.alwaysAvailableTools)
        // Admit run_code only when this chat has ≥1 enabled skill.
        if !enabledSkillRefs.isEmpty {
            enabledTools.insert("run_code")
        }
        // Lazy-connect configured MCP servers on the first send of the
        // session so their tools land in the registry before we read it.
        // The MCPRegistry tracks loaded-once internally; subsequent
        // sends are a single guard check.
        let mcpRegistry = environment.mcpRegistry
        let mcpServers = environment.mcpServers
        streamTask = Task { [weak self, assistantIndex] in
            guard let self else { return }
            await mcpRegistry.ensureLoaded(servers: mcpServers)
            await ChatTaskContext.$attachedCollections.withValue(attachedCollections) {
              await ChatTaskContext.$enabledSkills.withValue(enabledSkillRefs) {
               await ChatTaskContext.$calendarWritesAllowed.withValue(calendarWritesAllowed) {
                await ChatTaskContext.$reminderWritesAllowed.withValue(reminderWritesAllowed) {
                do {
                    let allDefinitions = await registry.definitions(for: promptLanguage)
                    // MCP tools admitted unconditionally; built-ins gated
                    // by the Settings → Tools toggles via enabledTools.
                    let toolDefinitions = allDefinitions.filter { def in
                        enabledTools.contains(def.name) || def.name.hasPrefix("mcp__")
                    }

                    let request = try await self.buildRequestWithCompactIfNeeded(
                        providerRecord: providerRecord,
                        modelID: trimmedModel,
                        language: promptLanguage,
                        toolDefinitions: toolDefinitions,
                        llm: llm,
                        budget: budget,
                        userMessageID: failureMessageID
                    )
                    for try await event in runner.run(initial: request) {
                        // Honour Stop at event granularity: a large buffered chunk
                        // can contain many events, so check per-event rather than
                        // only at chunk boundaries.
                        try Task.checkCancellation()
                        await self.apply(event: event, assistantIndex: assistantIndex)
                    }
                } catch {
                    let rendered = ChatViewModel.describe(error: error)
                    FileHandle.standardError.write(Data("[FyxLocal] chat turn failed: \(rendered) — raw: \(error)\n".utf8))
                    self.lastError = rendered
                    self.failedUserMessageID = failureMessageID
                    // Drop the empty assistant placeholder we appended; the user
                    // shouldn't see a blank assistant card next to a failed turn.
                    self.conversation.messages.removeAll { $0.id == assistantMessageID }
                }
                self.isStreaming = false
                self.environment?.update(self.conversation)
                self.refreshProjectionNow()
                self.maybeAutoTitle(providerRecord: providerRecord, modelID: trimmedModel, language: promptLanguage)
                }
               }
              }
            }
        }
    }

    /// Fire the auto-titler exactly once per chat, on the first successful
    /// assistant turn, when the user hasn't already named the chat. Runs on
    /// a detached task so a slow titler doesn't keep the streamTask alive.
    private func maybeAutoTitle(providerRecord: ProviderRecord, modelID: String, language: PromptLanguage) {
        guard !didAutoTitle else { return }
        guard conversation.title == "New chat" else { return }
        guard let firstUser = conversation.messages.first(where: { $0.role == .user })?.plainText,
              !firstUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let firstAssistant = conversation.messages.first(where: { $0.role == .assistant })?.plainText,
              !firstAssistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        didAutoTitle = true

        let environment = self.environment
        let provider = environment?.makeRuntimeProvider(for: providerRecord)
        guard let provider else { return }
        Task.detached(priority: .background) { [weak self, firstUser, firstAssistant] in
            let titler = ConversationTitler(provider: provider, modelID: modelID, language: language)
            do {
                let title = try await titler.title(forFirstUser: firstUser, firstAssistant: firstAssistant)
                await MainActor.run {
                    guard let self else { return }
                    // Recheck the guard — user may have renamed during the LLM call.
                    guard self.conversation.title == "New chat" else { return }
                    self.conversation.title = title
                }
            } catch {
                FileHandle.standardError.write(Data("[FyxLocal] auto-title failed: \(error)\n".utf8))
            }
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

    // MARK: - Per-message actions (copy / edit / regenerate / delete)

    /// A message action that would discard later turns, staged for the user to
    /// confirm before it runs. `discardCount` is the number of messages that
    /// will be removed *after* the target (drives the warning copy). Actions
    /// that discard nothing run immediately and never stage one of these.
    struct PendingMessageAction: Identifiable, Equatable {
        enum Kind: Equatable { case edit, regenerate, delete }
        let id = UUID()
        let kind: Kind
        let messageID: MessageID
        let discardCount: Int
    }

    /// Set when an edit/regenerate/delete needs confirmation because it would
    /// drop later messages. The detail view mirrors this into a confirmation
    /// dialog; confirming calls `commitPendingMessageAction()`.
    var pendingMessageAction: PendingMessageAction?

    /// How many messages sit after the one with `id` (i.e. would be discarded
    /// by an edit/regenerate that truncates from it). Returns 0 if not found.
    func messagesAfter(_ id: MessageID) -> Int {
        guard let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return 0 }
        return conversation.messages.count - 1 - index
    }

    /// Copy a message's plain text to the system pasteboard. Skips reasoning,
    /// tool calls, and images — just the readable text (`Message.plainText`).
    /// Allowed mid-stream: it's read-only.
    func copyMessage(_ id: MessageID) {
        guard let message = conversation.messages.first(where: { $0.id == id }) else { return }
        Clipboard.copy(message.plainText)
    }

    /// Delete a single message, then sweep orphaned blobs. Removing a message
    /// that carried an image/attachment would otherwise leak its blob file.
    /// Mid-stream deletes are refused (the streaming row is being written to).
    func deleteMessage(_ id: MessageID) {
        guard !isStreaming else { return }
        conversation.messages.removeAll { $0.id == id }
        conversation.updatedAt = .now
        // Clear stale error/retry state if we just removed the failed message.
        if failedUserMessageID == id {
            failedUserMessageID = nil
            lastError = nil
        }
        environment?.gcBlobs()
    }

    /// Edit a user message: truncate the transcript from that message onward,
    /// drop its text back into the composer for the user to revise and resend.
    /// Linear (truncate + resend), mirroring `retryLastFailedMessage`. Only
    /// valid on `.user` rows; refused mid-stream.
    func editUserMessage(_ id: MessageID) {
        guard !isStreaming else { return }
        guard let index = conversation.messages.firstIndex(where: { $0.id == id }),
              conversation.messages[index].role == .user else { return }
        let text = conversation.messages[index].plainText
        // NOTE: first cut prefills text only. Image/attachment parts of the
        // edited user message are dropped — re-attach them in the composer if
        // needed. Preserving them on edit is a noted nice-to-have.
        conversation.messages.removeSubrange(index...)
        conversation.updatedAt = .now
        failedUserMessageID = nil
        lastError = nil
        draftText = text
        environment?.gcBlobs()
    }

    /// Regenerate an assistant message: delete it and everything after it, then
    /// stream a fresh reply from the preceding context (no new user message).
    /// Refused mid-stream.
    func regenerateAssistantMessage(_ id: MessageID) {
        guard !isStreaming else { return }
        guard let environment, let resolved = resolveActiveProvider() else { return }
        guard let index = conversation.messages.firstIndex(where: { $0.id == id }),
              conversation.messages[index].role == .assistant else { return }
        // The user turn this assistant reply was answering — the Retry target
        // if the regenerate fails. May be nil for an orphaned leading reply.
        let priorUserID = conversation.messages[..<index]
            .last(where: { $0.role == .user })?.id

        // Drop the assistant reply and any messages that followed it.
        conversation.messages.removeSubrange(index...)
        failedUserMessageID = nil
        lastError = nil
        environment.gcBlobs()

        // Append a fresh empty assistant placeholder and stream into it.
        let assistantMessage = Message(role: .assistant, contentItems: [])
        conversation.messages.append(assistantMessage)
        let assistantIndex = conversation.messages.count - 1
        conversation.updatedAt = .now

        runAssistantTurn(
            providerRecord: resolved.provider,
            trimmedModel: resolved.model,
            budget: resolved.budget,
            assistantIndex: assistantIndex,
            assistantMessageID: assistantMessage.id,
            failureMessageID: priorUserID ?? assistantMessage.id
        )
    }

    /// Run the action the user just confirmed in the discard-warning dialog.
    func commitPendingMessageAction() {
        guard let action = pendingMessageAction else { return }
        pendingMessageAction = nil
        switch action.kind {
        case .edit:       editUserMessage(action.messageID)
        case .regenerate: regenerateAssistantMessage(action.messageID)
        case .delete:     deleteMessage(action.messageID)
        }
    }

    func cancelPendingMessageAction() {
        pendingMessageAction = nil
    }

    /// Resolve the active provider record, its trimmed default model, and the
    /// effective context budget — the trio every streaming turn needs. Mirrors
    /// the resolution `send()` does inline. Returns nil if unconfigured.
    private func resolveActiveProvider() -> (provider: ProviderRecord, model: String, budget: ContextBudget)? {
        guard let environment, let provider = environment.currentProvider() else { return nil }
        let model = (provider.defaultModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        let modelInfo = environment.detectedModels[provider.id]?.first(where: { $0.id == model })
        let budget = ContextBudget.resolve(settings: provider.context, model: modelInfo)
        return (provider, model, budget)
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
        userMessageID: MessageID
    ) async throws -> ChatRequest {
        let tokenizer = TokenizerCache.shared.get(modelID: modelID)
        let builder = RequestPayloadBuilder(tokenizer: tokenizer)
        let instructions = composeInstructions(language: language)
        // Trigger placeholder-substitution of older tool results when the
        // projected payload is past half of the safe budget. The two most
        // recent results stay verbatim so the model can keep working with
        // its latest data; older bodies are replaced with a tiny JSON
        // placeholder. Mirrors the Anthropic `clear_tool_uses` pattern.
        let clearOptions = ClearOptions(
            triggerTokens: max(1, budget.safeInputBudget / 2),
            keepRecentResults: 2,
            tokenizer: tokenizer
        )
        // Day-bucketed "[Today is ...]" header to prepend, invisibly, to
        // the latest user message at the wire layer. Keeps the system
        // prompt byte-stable across the entire session so vLLM's prefix
        // cache survives across turns. See TemporalContext for rationale.
        let todayHeader = TemporalContext(language: language).renderDayHeader()

        // Determine the active compaction state: keep range starts after the
        // most recent compaction's upper bound, if any.
        let currentMessageCount = conversation.messages.count
        // A prior compaction's toIndex is only valid while messages stay
        // append-only; clamp so an imported/mutated conversation can't produce an
        // inverted (lower > upper) keep range and trap.
        let firstKeepableIndex = min(conversation.compactions.last?.toIndex ?? 0, currentMessageCount)

        // Project the cost without any further compaction. Reuses the
        // per-message token-count cache so the send-path doesn't re-tokenise
        // every message from scratch on each send (~240ms saved at 50 msgs).
        let projection = builder.project(
            conversation: conversation,
            draftUserText: "",
            instructions: instructions,
            toolDefinitions: toolDefinitions,
            summary: existingSummariesConcatenated(),
            keepRange: firstKeepableIndex..<currentMessageCount,
            cache: tokenCountCache
        )

        let projectedTotal = projection.totalTokens
        let needsCompact = projectedTotal >= budget.compactionTrigger

        var summary = existingSummariesConcatenated()
        var keepLowerBound = firstKeepableIndex

        if needsCompact {
            // This method is MainActor-isolated (the class is @MainActor), so set
            // the flag directly and clear it synchronously on scope exit. The old
            // `defer { Task { … } }` scheduled a *future* hop, leaving isCompacting
            // briefly inconsistent (and racy on a thrown error).
            isCompacting = true
            defer { isCompacting = false }

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
                        keepRange: firstKeepableIndex..<currentMessageCount,
                        clearOptions: clearOptions,
                        todayHeader: todayHeader
                    ),
                    tools: toolDefinitions
                )
                await cacheContextSize(messageID: userMessageID, tokens: projectedTotal)
                return request
            }

            let summarizeFrom = firstKeepableIndex
            // Clamp to the current message count. Compaction indices are valid
            // only while messages are append-only; an imported/mutated
            // conversation could make summarizeTo exceed the array and crash the
            // slice. Guard the range rather than trap; if there's nothing safe to
            // summarize, fall through and send with the clamped keep range.
            let summarizeTo = min(firstKeepableIndex + pivotOffset, conversation.messages.count)
            if summarizeFrom < summarizeTo {
                let summarizer = ConversationSummarizer(provider: llm, modelID: modelID, language: language)
                let slice = conversation.messages[summarizeFrom..<summarizeTo]
                let freshSummary = try await summarizer.summarize(messages: slice)

                let record = CompactionRecord(
                    fromIndex: summarizeFrom,
                    toIndex: summarizeTo,
                    summary: freshSummary
                )
                self.conversation.compactions.append(record)

                // Now compose the combined summary (existing + fresh) and shift
                // the keep range to after the new compaction.
                summary = existingSummariesConcatenated(plus: freshSummary)
                keepLowerBound = summarizeTo
            }
        }

        let inputs = builder.assemble(
            conversation: conversation,
            draftUserText: "",
            summary: summary,
            keepRange: keepLowerBound..<currentMessageCount,
            clearOptions: clearOptions,
            todayHeader: todayHeader
        )
        // Re-project with the now-current shape and cache for the footer.
        let finalProjection = builder.project(
            conversation: conversation,
            draftUserText: "",
            instructions: instructions,
            toolDefinitions: toolDefinitions,
            summary: summary,
            keepRange: keepLowerBound..<currentMessageCount,
            cache: tokenCountCache
        )
        await cacheContextSize(messageID: userMessageID, tokens: finalProjection.totalTokens)
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
            // Ask the server to stream a chain-of-thought summary so the
            // user sees what the model is thinking. Without this vLLM /
            // OpenAI run reasoning silently and we just see a long gap
            // followed by the final answer with no in-between feedback.
            reasoningSummary: .auto,
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

    /// Strip leading whitespace from a freshly-opened assistant text block,
    /// preserving the exact `^[\s]+` regex semantics used previously but
    /// skipping the regex entirely when the string can't start with `\s`.
    /// `CharacterSet.whitespacesAndNewlines` is a superset of the regex's `\s`,
    /// so the guard never skips a string the regex would have trimmed — the
    /// output is byte-identical to calling the regex unconditionally.
    static func strippingLeadingWhitespace(_ s: String) -> String {
        guard let first = s.unicodeScalars.first,
              CharacterSet.whitespacesAndNewlines.contains(first) else { return s }
        return s.replacingOccurrences(of: "^[\\s]+", with: "", options: .regularExpression)
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
                let trimmedDelta = Self.strippingLeadingWhitespace(delta)
                if !trimmedDelta.isEmpty {
                    message.contentItems.append(.text(trimmedDelta))
                }
            }
        case .textCompleted(_, let full):
            let trimmed = Self.strippingLeadingWhitespace(full)
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
        case .reasoningCompleted(_, let text, let signature):
            // Signed (Anthropic) thinking upgrades the streamed summary to a
            // replayable .thinking item — same text, plus the signature the
            // API demands back during tool loops. Unsigned completions keep
            // the accumulated summary as-is.
            if let signature {
                let upgraded = MessageContent.thinking(text: text, signature: signature)
                if case .reasoningSummary = message.contentItems.last {
                    message.contentItems[message.contentItems.count - 1] = upgraded
                } else {
                    message.contentItems.append(upgraded)
                }
            }
        case .redactedThinking(_, let data):
            message.contentItems.append(.redactedThinking(data: data))
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

// MARK: - Composer attachments

/// An item staged in the composer for the next send.
struct PendingAttachment: Identifiable, Hashable {
    enum Kind: Hashable {
        case image(data: Data, mimeType: String)
        case textFile(contents: String)
    }
    let id = UUID()
    let filename: String
    let kind: Kind

    var isImage: Bool { if case .image = kind { return true }; return false }
}

extension ChatViewModel {
    /// Max size for an inlined text-file attachment. Larger files are refused so
    /// a giant file can't silently blow the context window.
    static let maxTextAttachmentBytes = 1_000_000  // ~1 MB

    /// Whether the active provider's default model accepts image input (user
    /// override, else the detected/catalog capability). Gates the composer's
    /// image-attach affordance.
    var activeModelAcceptsImages: Bool {
        guard let environment,
              let provider = environment.currentProvider(),
              let model = provider.defaultModel, !model.isEmpty
        else { return false }
        let detected = environment.detectedModels[provider.id] ?? []
        return provider.acceptsImages(modelID: model, detected: detected)
    }

    /// True when there's something to send (text or attachments) and we're idle.
    var canSend: Bool {
        !isStreaming
            && (!draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draftAttachments.isEmpty)
    }

    /// Ingest a picked/dropped file into a pending attachment. Images are only
    /// accepted when the active model supports vision; text files always. Returns
    /// an error string to surface in the composer, or nil on success.
    @discardableResult
    func addAttachment(from url: URL) -> String? {
        let filename = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            return String(localized: "Couldn't read \(filename).")
        }
        if let mime = Self.imageMimeType(for: url) {
            guard activeModelAcceptsImages else {
                return String(localized: "This model doesn't accept images. Enable image input for it in Settings → Providers.")
            }
            draftAttachments.append(PendingAttachment(filename: filename, kind: .image(data: data, mimeType: mime)))
            return nil
        }
        // Treat everything else as a text file: inline its contents.
        guard data.count <= Self.maxTextAttachmentBytes else {
            return String(localized: "\(filename) is too large to attach as text (over 1 MB).")
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            return String(localized: "\(filename) isn't a readable text file.")
        }
        draftAttachments.append(PendingAttachment(filename: filename, kind: .textFile(contents: contents)))
        return nil
    }

    func removeAttachment(_ attachment: PendingAttachment) {
        draftAttachments.removeAll { $0.id == attachment.id }
    }

    /// Image MIME type for a file URL by extension, or nil if not a supported image.
    static func imageMimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return nil
        }
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

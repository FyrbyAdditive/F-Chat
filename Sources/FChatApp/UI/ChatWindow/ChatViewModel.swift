import Foundation
import Observation
import FChatCore
import FChatProviders
import FChatTools

@MainActor
@Observable
final class ChatViewModel {
    var conversation: Conversation {
        didSet { environment?.update(conversation) }
    }
    var draftText: String = ""
    var isStreaming: Bool = false
    var lastError: String?
    private weak var environment: AppEnvironment?
    private var streamTask: Task<Void, Never>?
    private var firstDeltaAt: Date?

    init(conversation: Conversation, environment: AppEnvironment) {
        self.conversation = conversation
        self.environment = environment
    }

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

        let userMessage = Message(role: .user, contentItems: [.text(userText)])
        conversation.messages.append(userMessage)
        conversation.updatedAt = .now
        let assistantMessage = Message(role: .assistant, contentItems: [])
        conversation.messages.append(assistantMessage)
        let assistantIndex = conversation.messages.count - 1

        let registry = environment.toolRegistry
        let promptLanguage = environment.promptLanguage
        let llm = environment.makeRuntimeProvider(for: providerRecord)
        let runner = ChatTurnRunner(provider: llm, registry: registry, maxIterations: providerRecord.sampling.maxToolIterations)

        let initialRequest = buildRequest(
            userText: userText,
            language: promptLanguage,
            providerRecord: providerRecord,
            modelID: trimmedModel
        )

        isStreaming = true
        lastError = nil
        firstDeltaAt = nil
        let enabledTools = environment.enabledTools
        streamTask = Task { [weak self, assistantIndex] in
            guard let self else { return }
            do {
                let allDefinitions = await registry.definitions(for: promptLanguage)
                let toolDefinitions = allDefinitions.filter { enabledTools.contains($0.name) }
                var request = initialRequest
                request.tools = toolDefinitions
                for try await event in runner.run(initial: request) {
                    await self.apply(event: event, assistantIndex: assistantIndex)
                }
            } catch {
                let rendered = ChatViewModel.describe(error: error)
                FileHandle.standardError.write(Data("[FChat] chat turn failed: \(rendered) — raw: \(error)\n".utf8))
                self.lastError = rendered
            }
            self.isStreaming = false
            self.environment?.update(self.conversation)
        }
    }

    func cancel() {
        streamTask?.cancel()
        isStreaming = false
    }

    /// Render an `Error` in a form that's actually useful: prefers
    /// `LocalizedError.errorDescription`, then `CustomDebugStringConvertible`,
    /// finally the enum case name + associated values via reflection. This
    /// replaces the unhelpful "TheModule.SomeEnum error 0" macOS produces by
    /// default for Swift enums that don't conform to `LocalizedError`.
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

    private func buildRequest(
        userText: String,
        language: PromptLanguage,
        providerRecord: ProviderRecord,
        modelID: String
    ) -> ChatRequest {
        var historyInput: [InputItem] = []
        let prompt = LocalizedSystemPrompt(
            language: language,
            includeToolGuidance: true,
            includeRAGGuidance: !conversation.settings.attachedCollections.isEmpty
        )
        for message in conversation.messages.dropLast(1) {
            let content: [InputContent] = message.contentItems.compactMap { item in
                if case .text(let s) = item { return .inputText(s) }
                return nil
            }
            guard !content.isEmpty else { continue }
            historyInput.append(.message(role: message.role, content: content))
        }
        // Stateless mode: we always resend the full transcript and never reference
        // `previous_response_id`. vLLM and most self-hosted OpenAI-compatible
        // servers don't persist responses across requests, so chaining by id
        // 404s on the second turn. Trading a slightly larger payload for
        // portability is the right call until we add per-provider capability
        // detection.
        let sampling = providerRecord.sampling
        let temporal = TemporalContext(language: language).render()
        let instructions = prompt.render() + "\n\n" + temporal
        return ChatRequest(
            model: modelID,
            input: historyInput,
            instructions: instructions,
            previousResponseID: nil,
            temperature: sampling.temperature,
            topP: sampling.topP,
            maxOutputTokens: sampling.maxOutputTokens,
            reasoningEffort: conversation.reasoningEffort,
            parallelToolCalls: sampling.parallelToolCalls,
            tools: [],
            toolChoice: .auto,
            store: false
        )
    }

    private func apply(event: ChatTurnEvent, assistantIndex: Int) async {
        guard conversation.messages.indices.contains(assistantIndex) else { return }
        var message = conversation.messages[assistantIndex]
        // Start the generation clock the first time any content arrives so
        // tokens/sec excludes server queueing + first-token latency.
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
            // Coalesce streaming deltas into the trailing text item rather than
            // appending one new .text per token. With many deltas the
            // VStack(spacing: 8) in MessageView would otherwise produce visible
            // vertical gaps between every token.
            if case .text(let existing) = message.contentItems.last {
                message.contentItems[message.contentItems.count - 1] = .text(existing + delta)
            } else {
                // Drop leading whitespace some models emit before the first
                // visible character (e.g. MiniMax-M2.7 starts replies with "\n\n").
                let trimmedDelta = delta.replacingOccurrences(
                    of: "^[\\s]+", with: "", options: .regularExpression
                )
                if !trimmedDelta.isEmpty {
                    message.contentItems.append(.text(trimmedDelta))
                }
            }
        case .textCompleted(_, let full):
            // Replace trailing streamed text with the canonical assembled text
            // and trim leading whitespace some models emit (e.g. MiniMax-M2.7
            // on vLLM tends to lead with "\n\n").
            let trimmed = full.replacingOccurrences(
                of: "^[\\s]+", with: "", options: .regularExpression
            )
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
            // Arguments fully arrived but the tool itself hasn't run yet —
            // keep the spinner going (.running) until .toolResult lands.
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
            // Some servers omit `usage` from the SSE stream; still finalise
            // the clock so the UI stops the "streaming" treatment cleanly.
            if message.generationDuration == nil, let start = firstDeltaAt {
                message.generationDuration = Date.now.timeIntervalSince(start)
            }
        }
        conversation.messages[assistantIndex] = message
        conversation.updatedAt = .now
    }
}

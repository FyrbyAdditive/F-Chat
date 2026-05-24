import Foundation
import FChatCore

/// Translates a `Conversation` plus a pending user draft into the structured
/// input items the provider wants, while counting tokens and reporting
/// where they go.
///
/// This is the single source of truth for the question "what would be sent
/// to the model if I hit send right now?". The chat view-model uses it for
/// the budget meter (dry-run / projection) and for the actual send.
public struct RequestPayloadBuilder: Sendable {
    public let tokenizer: any Tokenizer

    public init(tokenizer: any Tokenizer) {
        self.tokenizer = tokenizer
    }

    /// Build the input array for a turn, including everything from the
    /// conversation history that the model needs to see.
    ///
    /// - Parameter conversation: the chat history.
    /// - Parameter draftUserText: the message about to be sent; pass an
    ///   empty string for pure projection ("how big would the next send
    ///   be if I sent nothing extra?").
    /// - Parameter summary: an optional pre-computed summary that should
    ///   appear before the kept history (used when auto-compaction runs).
    ///   When provided, only the messages whose indices fall in
    ///   `keepRange` are included as message items.
    /// - Parameter keepRange: indices into `conversation.messages` of the
    ///   messages to include verbatim. When `summary` is nil, all messages
    ///   are kept.
    public func assemble(
        conversation: Conversation,
        draftUserText: String,
        summary: String? = nil,
        keepRange: Range<Int>? = nil
    ) -> [InputItem] {
        var input: [InputItem] = []

        if let summary, !summary.isEmpty {
            input.append(.message(
                role: .system,
                content: [.inputText("Summary of earlier conversation:\n\(summary)")]
            ))
        }

        let indicesToInclude: Range<Int>
        if let keepRange {
            let clamped = max(0, keepRange.lowerBound)..<min(conversation.messages.count, keepRange.upperBound)
            indicesToInclude = clamped
        } else {
            indicesToInclude = 0..<conversation.messages.count
        }

        for index in indicesToInclude {
            let message = conversation.messages[index]
            input.append(contentsOf: messageItems(for: message))
        }

        let trimmed = draftUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            input.append(.message(role: .user, content: [.inputText(trimmed)]))
        }

        return input
    }

    /// Lower a single chat message into one or more InputItems. Critically,
    /// this includes tool calls and tool results — the previous behaviour
    /// stripped them, so the model lost its own tool history across turns.
    public func messageItems(for message: Message) -> [InputItem] {
        var items: [InputItem] = []
        var textRuns: [InputContent] = []

        for item in message.contentItems {
            switch item {
            case .text(let s):
                textRuns.append(.inputText(s))

            case .reasoningSummary:
                // Reasoning summaries are display-only; the server doesn't
                // accept them as input and they leak detail that would
                // bias future turns. Always dropped from the sent payload.
                break

            case .toolCall(let rec):
                // Flush any accumulated text first so message ordering stays
                // right (text → toolCall → … → text rather than re-ordering).
                if !textRuns.isEmpty {
                    items.append(.message(role: message.role, content: textRuns))
                    textRuns.removeAll(keepingCapacity: true)
                }
                items.append(.functionCall(
                    callID: rec.id,
                    name: rec.name,
                    argumentsJSON: rec.argumentsJSON.isEmpty ? "{}" : rec.argumentsJSON
                ))

            case .toolResult(let rec):
                if !textRuns.isEmpty {
                    items.append(.message(role: message.role, content: textRuns))
                    textRuns.removeAll(keepingCapacity: true)
                }
                items.append(.functionCallOutput(callID: rec.callID, outputJSON: rec.outputJSON))

            case .image(let data, let mimeType):
                let base64 = data.base64EncodedString()
                textRuns.append(.inputImageData(base64: base64, mimeType: mimeType))

            case .attachment:
                // Out of band; attachments aren't supported in the OpenAI
                // Responses input shape we use. Future work.
                break
            }
        }

        if !textRuns.isEmpty {
            items.append(.message(role: message.role, content: textRuns))
        }

        // A message with no surviving content shouldn't appear at all.
        return items
    }

    // MARK: - Token accounting

    /// Coarse projection of the token cost of a candidate send.
    public struct Projection: Sendable, Hashable {
        public var totalTokens: Int
        public var systemTokens: Int
        public var historyTokens: Int
        public var draftTokens: Int
        public var toolDefinitionTokens: Int

        public init(
            totalTokens: Int,
            systemTokens: Int,
            historyTokens: Int,
            draftTokens: Int,
            toolDefinitionTokens: Int
        ) {
            self.totalTokens = totalTokens
            self.systemTokens = systemTokens
            self.historyTokens = historyTokens
            self.draftTokens = draftTokens
            self.toolDefinitionTokens = toolDefinitionTokens
        }
    }

    public func project(
        conversation: Conversation,
        draftUserText: String,
        instructions: String,
        toolDefinitions: [ToolDefinition],
        summary: String? = nil,
        keepRange: Range<Int>? = nil
    ) -> Projection {
        let systemTokens = tokenizer.countTokens(in: instructions)
            + (summary.map { tokenizer.countTokens(in: "Summary of earlier conversation:\n\($0)") } ?? 0)
        var historyTokens = 0
        let indices: Range<Int>
        if let keepRange {
            let clamped = max(0, keepRange.lowerBound)..<min(conversation.messages.count, keepRange.upperBound)
            indices = clamped
        } else {
            indices = 0..<conversation.messages.count
        }
        for index in indices {
            historyTokens += countTokens(in: conversation.messages[index])
        }
        let draftTokens = tokenizer.countTokens(in: draftUserText)
        let toolTokens = toolDefinitions.reduce(0) { sum, def in
            sum + tokenizer.countTokens(in: def.name)
            + tokenizer.countTokens(in: def.description)
            + tokenizer.countTokens(in: def.parametersSchema.raw)
        }
        // Add a small constant per message to reflect role + framing overhead
        // (OpenAI counts ~3 tokens per message envelope). Coarse but useful.
        let envelopeOverhead = (indices.count + (draftTokens > 0 ? 1 : 0)) * 3
        let total = systemTokens + historyTokens + draftTokens + toolTokens + envelopeOverhead
        return Projection(
            totalTokens: total,
            systemTokens: systemTokens,
            historyTokens: historyTokens,
            draftTokens: draftTokens,
            toolDefinitionTokens: toolTokens
        )
    }

    /// Count tokens in all surviving content of a single message (text +
    /// tool calls + tool results). Reasoning summaries are excluded
    /// because they're dropped from the sent payload.
    public func countTokens(in message: Message) -> Int {
        var total = 0
        for item in message.contentItems {
            switch item {
            case .text(let s):
                total += tokenizer.countTokens(in: s)
            case .reasoningSummary:
                break
            case .toolCall(let rec):
                total += tokenizer.countTokens(in: rec.name)
                total += tokenizer.countTokens(in: rec.argumentsJSON.isEmpty ? "{}" : rec.argumentsJSON)
                total += 4 // framing overhead per call
            case .toolResult(let rec):
                total += tokenizer.countTokens(in: rec.outputJSON)
                total += 4
            case .image(let data, _):
                // Rough placeholder: low/medium-detail images use ~85 / ~170
                // tokens on OpenAI. We treat all images as ~150 to be safe.
                total += 150
                _ = data
            case .attachment:
                break
            }
        }
        return total
    }
}


// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import os
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
        keepRange: Range<Int>? = nil,
        clearOptions: ClearOptions? = nil,
        todayHeader: String? = nil
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

        if let clearOptions {
            input = applyClearing(to: input, options: clearOptions)
        }

        if let todayHeader, !todayHeader.isEmpty {
            input = prependTodayHeader(to: input, header: todayHeader)
        }

        return input
    }

    /// Find the most recent `.message(role: .user, ...)` item and prepend the
    /// day-bucketed header to its first `.inputText` content part. Other
    /// user messages in the history stay untouched — prefix-cache-stable.
    /// Silently no-ops when the assembled input has no user message.
    private func prependTodayHeader(to items: [InputItem], header: String) -> [InputItem] {
        // Walk backwards looking for the latest user message with at least
        // one inputText content part.
        for i in stride(from: items.count - 1, through: 0, by: -1) {
            guard case .message(let role, var content) = items[i], role == .user else { continue }
            // Find the first inputText content part in this message and
            // prepend the header. If the user sent an image-only message
            // we'd have no text to prepend to; insert a text part instead.
            if let textIdx = content.firstIndex(where: {
                if case .inputText = $0 { return true } else { return false }
            }) {
                if case .inputText(let existing) = content[textIdx] {
                    content[textIdx] = .inputText("\(header)\n\(existing)")
                }
            } else {
                content.insert(.inputText(header), at: 0)
            }
            var mutated = items
            mutated[i] = .message(role: role, content: content)
            return mutated
        }
        return items
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

            case .image(let ref):
                if let data = item.imageData {
                    textRuns.append(.inputImageData(base64: data.base64EncodedString(), mimeType: ref.mimeType))
                }

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
        keepRange: Range<Int>? = nil,
        cache: MessageTokenCountCache? = nil
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
            let message = conversation.messages[index]
            if let cache {
                historyTokens += cache.countTokens(in: message, using: self)
            } else {
                historyTokens += countTokens(in: message)
            }
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
            case .image:
                // Rough placeholder: low/medium-detail images use ~85 / ~170
                // tokens on OpenAI. We treat all images as ~150 to be safe.
                total += 150
            case .attachment:
                break
            }
        }
        return total
    }

    // MARK: - Threshold-clear of older tool results

    private func applyClearing(to items: [InputItem], options: ClearOptions) -> [InputItem] {
        // Locate every `.functionCallOutput` item and its position.
        var resultPositions: [Int] = []
        for (i, item) in items.enumerated() {
            if case .functionCallOutput = item { resultPositions.append(i) }
        }
        // Nothing to do if we have at-or-under the keep window.
        guard resultPositions.count > options.keepRecentResults else { return items }

        // Cheap upper bound on total token cost: tokenise the text payload
        // of every item once. Cheap because tool results dominate cost and
        // we'd be tokenising them anyway for the placeholder.
        func tokens(of item: InputItem) -> Int {
            switch item {
            case .message(_, let content):
                return content.reduce(0) { acc, part in
                    switch part {
                    case .inputText(let s), .outputText(let s):
                        return acc + options.tokenizer.countTokens(in: s)
                    case .inputImage:
                        return acc + 150
                    case .inputImageData:
                        return acc + 150
                    }
                }
            case .functionCall(_, _, let argsJSON):
                return options.tokenizer.countTokens(in: argsJSON)
            case .functionCallOutput(_, let outputJSON):
                return options.tokenizer.countTokens(in: outputJSON)
            case .reasoning:
                // Never include reasoning items in the budget — they're
                // dropped from outgoing payloads in our shape anyway.
                return 0
            }
        }

        var perItemTokens = items.map(tokens(of:))
        var total = perItemTokens.reduce(0, +)
        guard total > options.triggerTokens else { return items }

        // Clear oldest results first, preserving the last `keepRecentResults`.
        let clearUntil = resultPositions.count - options.keepRecentResults
        var mutated = items
        var cleared = 0
        for posIdx in 0..<clearUntil {
            guard total > options.triggerTokens else { break }
            let i = resultPositions[posIdx]
            guard case .functionCallOutput(let callID, let originalJSON) = mutated[i] else { continue }
            // Skip already-cleared placeholders — idempotent if assemble runs
            // a second time over the same conversation snapshot.
            if originalJSON.contains("\"_fchat_cleared\":true") { continue }
            let originalTokens = perItemTokens[i]
            let placeholder = clearedPlaceholderJSON(
                callID: callID,
                originalTokens: originalTokens
            )
            mutated[i] = .functionCallOutput(callID: callID, outputJSON: placeholder)
            let newTokens = options.tokenizer.countTokens(in: placeholder)
            total -= (originalTokens - newTokens)
            perItemTokens[i] = newTokens
            cleared += 1
        }
        if cleared > 0 {
            FileHandle.standardError.write(Data(
                "[FChat] cleared \(cleared) older tool result(s); projected tokens now \(total) (trigger \(options.triggerTokens))\n".utf8
            ))
        }
        return mutated
    }

    private func clearedPlaceholderJSON(callID: String, originalTokens: Int) -> String {
        // Escape the call_id defensively though they're already opaque strings.
        let safeCallID = callID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"_fchat_cleared\":true,\"call_id\":\"\(safeCallID)\",\"original_tokens\":\(originalTokens),\"hint\":\"This tool result was cleared by F-Chat to save context. Re-call the tool with the same arguments to refetch.\"}"
    }
}

// MARK: - ClearOptions

/// Opt-in policy for `RequestPayloadBuilder.assemble(...)` to replace older
/// tool outputs with small placeholders when the assembled payload exceeds
/// `triggerTokens`. Mirrors Anthropic's `clear_tool_uses_20250919` behaviour:
/// the most-recent N results are preserved verbatim; the oldest are cleared
/// first. The matching `function_call` items are never touched, so the model
/// still sees what it called and can re-call.
public struct ClearOptions: Sendable {
    public var triggerTokens: Int
    public var keepRecentResults: Int
    public var tokenizer: any Tokenizer

    public init(triggerTokens: Int, keepRecentResults: Int = 2, tokenizer: any Tokenizer) {
        self.triggerTokens = max(0, triggerTokens)
        self.keepRecentResults = max(0, keepRecentResults)
        self.tokenizer = tokenizer
    }
}

// MARK: - Per-message token-count cache

/// Memoises `RequestPayloadBuilder.countTokens(in: Message)` keyed by a cheap
/// content fingerprint. Lets `project(...)` skip re-tokenising the entire
/// transcript on every streaming delta — only the message whose content
/// changed (always the streaming tail) actually runs through BPE.
///
/// Fingerprint is order-of-magnitude derived state — `plainText.count`,
/// `contentItems.count`, and the sum of tool-call argument lengths. Cheap
/// to compute and collision-safe for our use (per-message identity is keyed
/// by `MessageID`; the hash only has to disambiguate that *one* message's
/// generations of itself, not different messages).
public final class MessageTokenCountCache: Sendable {
    private struct Entry {
        let fingerprint: Int
        let count: Int
    }

    // Protected state behind an OS unfair lock — Sendable-by-construction, so
    // the cache no longer needs `@unchecked Sendable` + a manual NSLock. Stays
    // synchronous so `RequestPayloadBuilder.project(...)` can call it inline; the
    // lock is only held for the dictionary read/write, never across the BPE call.
    private let entries = OSAllocatedUnfairLock<[MessageID: Entry]>(initialState: [:])

    public init() {}

    /// Returns the cached count for `message` if its content hasn't changed
    /// since the last query; otherwise tokenises via `builder` and caches.
    public func countTokens(in message: Message, using builder: RequestPayloadBuilder) -> Int {
        let fingerprint = Self.fingerprint(of: message)
        let cached = entries.withLock { $0[message.id] }
        if let cached, cached.fingerprint == fingerprint { return cached.count }
        let count = builder.countTokens(in: message)
        entries.withLock { $0[message.id] = Entry(fingerprint: fingerprint, count: count) }
        return count
    }

    /// Drop all cached counts. Call on conversation reload.
    public func reset() {
        entries.withLock { $0.removeAll(keepingCapacity: true) }
    }

    private static func fingerprint(of message: Message) -> Int {
        var hasher = Hasher()
        hasher.combine(message.contentItems.count)
        for item in message.contentItems {
            switch item {
            case .text(let s):
                hasher.combine(0)
                hasher.combine(s.count)
            case .reasoningSummary(let s):
                hasher.combine(1)
                hasher.combine(s.count)
            case .toolCall(let rec):
                hasher.combine(2)
                hasher.combine(rec.argumentsJSON.count)
                hasher.combine(rec.name.count)
            case .toolResult(let rec):
                hasher.combine(3)
                hasher.combine(rec.outputJSON.count)
            case .image(let ref):
                hasher.combine(4)
                hasher.combine(ref.sha256)
            case .attachment(let ref):
                hasher.combine(5)
                hasher.combine(ref.sha256)
            }
        }
        return hasher.finalize()
    }
}

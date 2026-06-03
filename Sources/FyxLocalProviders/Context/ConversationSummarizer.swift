// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// Calls the active provider to summarize a chunk of conversation history.
/// One retry on transient failure; surfaces structured error otherwise so
/// the caller (ChatViewModel) can show the user a Retry button.
public struct ConversationSummarizer: Sendable {
    public let provider: any LLMProvider
    public let modelID: String
    public let language: PromptLanguage

    public init(provider: any LLMProvider, modelID: String, language: PromptLanguage = .english) {
        self.provider = provider
        self.modelID = modelID
        self.language = language
    }

    /// Summarize the given messages. Returns the summary text on success.
    /// Throws `SummarizerError` after one auto-retry on the second failure.
    public func summarize(messages: ArraySlice<Message>) async throws -> String {
        let transcript = transcript(from: messages)
        let request = ChatRequest(
            model: modelID,
            input: [
                .message(role: .system, content: [.inputText(prompt(for: language))]),
                .message(role: .user, content: [.inputText(transcript)]),
            ],
            previousResponseID: nil,
            temperature: 0.2,
            tools: [],
            toolChoice: .none,
            store: false
        )

        do {
            return try await runOnce(request)
        } catch {
            // One quick retry.
            do {
                try await Task.sleep(for: .milliseconds(400))
                return try await runOnce(request)
            } catch {
                throw SummarizerError.failed(error.localizedDescription)
            }
        }
    }

    private func runOnce(_ request: ChatRequest) async throws -> String {
        var collected = ""
        for try await event in provider.streamResponse(request) {
            switch event {
            case .textDelta(_, let delta):
                collected += delta
            case .textCompleted(_, let full):
                collected = full
            case .responseError(let message, _):
                throw SummarizerError.failed(message)
            default:
                break
            }
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummarizerError.failed("summarizer returned no text")
        }
        return trimmed
    }

    private func transcript(from messages: ArraySlice<Message>) -> String {
        messages.map { message in
            let role = message.role.rawValue.uppercased()
            let body = message.contentItems.compactMap { item -> String? in
                switch item {
                case .text(let s):
                    return s
                case .toolCall(let rec):
                    return "[tool call: \(rec.name)(\(rec.argumentsJSON))]"
                case .toolResult(let rec):
                    return "[tool result for \(rec.callID): \(rec.outputJSON.prefix(400))]"
                case .reasoningSummary:
                    return nil
                case .image:
                    return "[image attached]"
                case .attachment(let ref):
                    return "[attachment: \(ref.filename ?? "attachment")]"
                }
            }.joined(separator: "\n")
            return "## \(role)\n\(body)"
        }.joined(separator: "\n\n")
    }

    private func prompt(for language: PromptLanguage) -> String {
        PromptStrings.string("summarizer.prompt", language)
    }
}

public enum SummarizerError: Error, Sendable, Equatable, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let detail):
            return "Conversation summarizer failed: \(detail)"
        }
    }
}

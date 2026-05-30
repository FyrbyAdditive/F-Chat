// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// Asks the active LLM provider to invent a short title summarising what a
/// brand-new chat is about, based on the first user message and the
/// assistant's first reply. Cheap one-shot non-streaming call; the result is
/// sanity-cleaned (quotes stripped, trailing punctuation removed, hard-capped
/// at 60 chars) before being returned.
public struct ConversationTitler: Sendable {
    public let provider: any LLMProvider
    public let modelID: String
    public let language: PromptLanguage

    /// Hard cap on the returned title length, applied even if the model
    /// ignores the prompt's "max 60 characters" instruction. Sidebar layout
    /// relies on titles staying short.
    public static let maxTitleLength: Int = 60

    public init(provider: any LLMProvider, modelID: String, language: PromptLanguage = .english) {
        self.provider = provider
        self.modelID = modelID
        self.language = language
    }

    public func title(forFirstUser user: String, firstAssistant: String) async throws -> String {
        let request = ChatRequest(
            model: modelID,
            input: [
                .message(role: .system, content: [.inputText(prompt(for: language))]),
                .message(role: .user, content: [.inputText(transcript(user: user, assistant: firstAssistant))]),
            ],
            previousResponseID: nil,
            temperature: 0.3,
            tools: [],
            toolChoice: .none,
            store: false
        )
        var collected = ""
        for try await event in provider.streamResponse(request) {
            switch event {
            case .textDelta(_, let delta):
                collected += delta
            case .textCompleted(_, let full):
                collected = full
            case .responseError(let message, _):
                throw TitlerError.failed(message)
            default:
                break
            }
        }
        return try Self.clean(collected)
    }

    /// Sanity-clean the model's raw output. Public + static so the test suite
    /// can hit every branch without mocking the provider stream.
    public static func clean(_ raw: String) throws -> String {
        // Take the first non-empty line — the model occasionally adds a
        // second-line "explanation" we don't want.
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? ""

        var s = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip wrapping quotes / smart quotes / backticks. Iterate so
        // "“Foo”" and "\"Foo\"" both fully unwrap.
        let wrappers: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("`", "`"),
            ("\u{201C}", "\u{201D}"), // “ ”
            ("\u{2018}", "\u{2019}"), // ‘ ’
        ]
        var changed = true
        while changed {
            changed = false
            for (open, close) in wrappers {
                if s.count >= 2, s.first == open, s.last == close {
                    s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }

        // Drop trailing punctuation that sentence-titles tend to pick up.
        while let last = s.last, ".!?;:,".contains(last) {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        // Hard cap. Truncate on a word boundary if possible.
        if s.count > maxTitleLength {
            let prefix = s.prefix(maxTitleLength)
            if let lastSpace = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: lastSpace) > maxTitleLength / 2 {
                s = String(prefix[..<lastSpace])
            } else {
                s = String(prefix)
            }
            s = s.trimmingCharacters(in: .whitespaces)
        }

        guard !s.isEmpty else { throw TitlerError.failed("titler returned no usable text") }
        return s
    }

    private func transcript(user: String, assistant: String) -> String {
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAssistant = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clip each side so a runaway opening message doesn't blow the
        // context budget on the titler call itself.
        let userClipped = String(trimmedUser.prefix(1000))
        let assistantClipped = String(trimmedAssistant.prefix(1000))
        return """
        User: \(userClipped)

        Assistant: \(assistantClipped)
        """
    }

    private func prompt(for language: PromptLanguage) -> String {
        switch language {
        case .english:
            return """
            You write a short title for a chat conversation. Look at the user's first message and the assistant's first reply, then output a title of at most 6 words and 60 characters that captures the topic. Use title case. No quotes, no trailing punctuation, no preamble. Just the title.
            """
        case .swedish:
            return """
            Du skriver en kort titel för en chattkonversation. Titta på användarens första meddelande och assistentens första svar, och skriv en titel på högst 6 ord och 60 tecken som fångar ämnet. Använd inledande versaler på huvudord. Inga citattecken, ingen avslutande interpunktion, ingen inledning. Bara titeln.
            """
        }
    }
}

public enum TitlerError: Error, Sendable, Equatable, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let detail):
            return "Conversation titler failed: \(detail)"
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders
@testable import FChatCore

/// Live integration tests against the dev magi endpoint
/// (`https://magi.fyrby.internal:8000/v1`). Disabled by default so CI /
/// unattended builds don't hit the network — set `FCHAT_LIVE_ENDPOINT=1`
/// to enable. The endpoint relies on the System Keychain holding the
/// right trust anchor.
@Suite("Magi live", .disabled(if: ProcessInfo.processInfo.environment["FCHAT_LIVE_ENDPOINT"] == nil, "set FCHAT_LIVE_ENDPOINT=1 to enable"))
struct MagiLiveTests {

    /// Drives the same outgoing wire shape `ChatViewModel.send` would
    /// produce: an `instructions` field with NO timestamp, an `input`
    /// array where the latest user message is prefixed with
    /// `[Today is …]\n`, and `reasoning.summary` set to auto. Asserts that
    /// (a) the server returns 200 (round-trip works) and (b) the streamed
    /// text response contains an answer to the date question — proving
    /// the model reads the day-bucketed header out of the user message.
    @Test func userMessageHeaderTellsModelTheDate() async throws {
        let provider = OpenAIResponsesProvider(
            id: ProviderID(rawValue: "magi-test"),
            baseURL: URL(string: "https://magi.fyrby.internal:8000/v1")!,
            secretStore: InMemorySecretStore()
        )
        let models = try await provider.listModels()
        let modelID = try #require(models.first?.id, "magi has no models")

        let today = TemporalContext(
            date: .now,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        ).renderDayHeader()
        // Verify the header itself has the expected shape before we send it.
        #expect(today.hasPrefix("[Today is "))

        let userText = "What is today's date? Reply with just the date."
        let request = ChatRequest(
            model: modelID,
            input: [
                .message(role: .user, content: [.inputText("\(today)\n\(userText)")])
            ],
            instructions: "You are a test assistant. Answer briefly.",
            temperature: 0.0,
            reasoningEffort: nil,
            reasoningSummary: .auto,
            tools: [],
            toolChoice: .auto,
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
                Issue.record("server returned response error: \(message)")
                return
            default:
                break
            }
        }

        // Two-signal check: reply must include the year AND either the
        // month name or the day-of-month. Year alone could be remembered
        // from training, but year + month or year + day proves the model
        // pulled the date out of the user-message header (and didn't
        // hallucinate). All three are stable signals across phrasings.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: .now)
        let year = String(comps.year!)
        let day = String(comps.day!)
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US")
        monthFormatter.timeZone = TimeZone(identifier: "UTC")!
        monthFormatter.dateFormat = "MMMM"
        let monthName = monthFormatter.string(from: .now)
        let monthNumber = String(comps.month!)
        let lower = collected.lowercased()

        let hasYear = lower.contains(year)
        let hasMonth = lower.contains(monthName.lowercased())
            || lower.contains(String(format: "-%02d-", comps.month!))
            || lower.contains("/\(monthNumber)/")
        let hasDay = lower.contains(" \(day)")
            || lower.contains("-\(day)")
            || lower.contains("/\(day)")
            || lower.contains(",\(day)")

        #expect(hasYear, "reply missing year \(year); got: \(collected)")
        #expect(hasMonth || hasDay,
                "reply missing both month (\(monthName)) and day (\(day)); got: \(collected)")
    }

}

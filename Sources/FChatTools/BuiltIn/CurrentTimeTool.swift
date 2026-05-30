// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatProviders

/// Built-in tool that returns the precise current date and time on demand.
/// Off-by-default in `defaultEnabledTools`: enabling it lets the model
/// answer sub-day-precision questions ("good morning", "how long ago",
/// scheduling) while keeping the system prompt prefix byte-stable for
/// users who don't need it. The system prompt itself never carries a
/// timestamp (see ChatViewModel.composeInstructions for the rationale).
public struct CurrentTimeTool: Tool {
    public let name = "current_time"

    public init() {}

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description: String
        switch language {
        case .english:
            description = "Returns the current date and time at second precision in the user's local time zone (or a named IANA zone if provided). Call this when the answer depends on precise time of day: scheduling, time-since calculations, greetings like \"good morning\". Don't call it just to confirm the date — the date is already supplied in each user message."
        case .swedish:
            description = "Returnerar aktuellt datum och tid med sekundprecision i användarens lokala tidszon (eller en namngiven IANA-zon om sådan anges). Anropa när svaret beror på exakt klockslag: schemaläggning, tidssedan-beräkningar, hälsningar som \"god morgon\". Anropa inte bara för att bekräfta datumet — datumet finns redan med i varje användarmeddelande."
        }
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"timezone":{"type":"string","description":"Optional IANA timezone identifier, e.g. 'Europe/Stockholm' or 'America/New_York'. Defaults to the user's local timezone."}},"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: false)
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        struct Args: Decodable { let timezone: String? }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.isEmpty ? "{}" : trimmed
        let parsed: Args = (try? JSONDecoder().decode(Args.self, from: Data(normalised.utf8))) ?? Args(timezone: nil)
        // Unrecognised timezone strings fall back to the user's local zone
        // rather than erroring — the model gets a useful answer either way.
        let tz = parsed.timezone
            .flatMap { TimeZone(identifier: $0) }
            ?? .current
        let context = TemporalContext(date: .now, timeZone: tz)
        return ToolOutput(outputJSON: context.renderFullJSON(), isError: false, display: .json)
    }
}

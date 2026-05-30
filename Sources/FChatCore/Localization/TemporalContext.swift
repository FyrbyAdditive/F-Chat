// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Builds a one- or two-line temporal preamble that gets appended to the
/// system instructions on every chat turn. Without this, models routinely
/// invent the date or default to their training cutoff. Including both a
/// machine-readable ISO-8601 stamp and a humanised, locale-formatted line
/// covers both cases.
public struct TemporalContext: Sendable {
    public var date: Date
    public var locale: Locale
    public var timeZone: TimeZone
    public var language: PromptLanguage

    public init(
        date: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        language: PromptLanguage = .resolve()
    ) {
        self.date = date
        self.locale = locale
        self.timeZone = timeZone
        self.language = language
    }

    /// Short day-bucketed header for inline prepend on user messages, e.g.
    /// `"[Today is Tuesday, May 26, 2026]"`. Stable for the entire local-day
    /// — calling this with two `date` values 30 minutes apart returns the
    /// same string. That stability is what makes it safe to prepend to a
    /// user message without invalidating any prefix cache: subsequent
    /// re-sends of the same conversation produce byte-identical bytes for
    /// every prior user turn.
    public func renderDayHeader() -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .full
        f.timeStyle = .none
        switch language {
        case .english:
            return "[Today is \(f.string(from: date))]"
        case .swedish:
            return "[Idag är \(f.string(from: date))]"
        }
    }

    /// Full sub-second precision rendering as a small JSON object, suitable
    /// as the output of a `current_time` tool. Includes ISO-8601, a
    /// human-readable string, and the named timezone.
    public func renderFullJSON() -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        let iso = isoFormatter.string(from: date)

        let humanFormatter = DateFormatter()
        humanFormatter.locale = locale
        humanFormatter.timeZone = timeZone
        humanFormatter.dateStyle = .full
        humanFormatter.timeStyle = .medium
        let human = humanFormatter.string(from: date)

        let tzName = timeZone.identifier
        let escape: (String) -> String = { s in
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        return "{\"iso8601\":\"\(escape(iso))\",\"human\":\"\(escape(human))\",\"timezone\":\"\(escape(tzName))\"}"
    }

    public func render() -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        let iso = isoFormatter.string(from: date)

        let humanFormatter = DateFormatter()
        humanFormatter.locale = locale
        humanFormatter.timeZone = timeZone
        humanFormatter.dateStyle = .full
        humanFormatter.timeStyle = .short
        let human = humanFormatter.string(from: date)

        let tzAbbrev = timeZone.abbreviation(for: date) ?? timeZone.identifier
        let tzName = timeZone.identifier

        switch language {
        case .english:
            return """
            The current date and time is \(human) (\(tzAbbrev), \(tzName)). \
            Machine-readable: \(iso). Use these when the question depends on \
            "today", "now", or how recent something is; do not rely on your \
            training cutoff for date-sensitive answers.
            """
        case .swedish:
            return """
            Aktuellt datum och tid är \(human) (\(tzAbbrev), \(tzName)). \
            Maskinläsbart: \(iso). Använd dessa när frågan beror på "idag", \
            "nu" eller hur färsk en händelse är; förlita dig inte på din \
            träningsdata för datumkänsliga svar.
            """
        }
    }

}

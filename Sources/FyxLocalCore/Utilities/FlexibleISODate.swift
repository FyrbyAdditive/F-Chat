// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public enum FlexibleISODate {
    /// Parse a date string an LLM supplied. Accepts full ISO-8601 with a timezone
    /// (`2026-06-06T15:00:00Z` / `+02:00`), ISO WITHOUT a zone (interpreted in the
    /// user's local time — the common case when the model just says "3pm"), and a
    /// plain `yyyy-MM-dd` date. The strict `ISO8601DateFormatter` rejects
    /// zone-less strings, which made the model's natural output fail — hence the
    /// DateFormatter fallbacks.
    ///
    /// (Formatters are built per call — `ISO8601DateFormatter` isn't `Sendable`,
    /// and this isn't a hot path.)
    public static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 1) Strict ISO-8601 with timezone (+ optional fractional seconds).
        let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: s) { return d }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }

        // 2) Zone-less / date-only forms, parsed in the user's local time zone.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = fmt
            if let d = local.date(from: s) { return d }
        }
        return nil
    }
}

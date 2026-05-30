// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore

@Suite("TemporalContext")
struct TemporalContextTests {
    /// A fixed reference moment used so the test asserts the exact strings
    /// the model will see — independent of when the test runs.
    /// 1_780_000_000 = 2026-05-28T20:26:40Z (Thursday).
    static let referenceDate = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func englishContainsISOAndHumanForms() {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        )
        let rendered = ctx.render()
        #expect(rendered.contains("2026-05-28T20:26:40Z"))   // ISO-8601
        #expect(rendered.contains("Thursday"))                // dateStyle: .full
        // Foundation canonicalises both `TimeZone(identifier: "UTC")!`
        // abbreviation and identifier to "GMT" on macOS, which is what the
        // LLM actually sees.
        #expect(rendered.contains("GMT"))
        #expect(rendered.contains("training cutoff"))
    }

    @Test func nonGMTZoneSurfacesIANAIdentifier() {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "Europe/Stockholm")!,
            language: .english
        )
        let rendered = ctx.render()
        #expect(rendered.contains("Europe/Stockholm"))
    }

    @Test func swedishUsesSwedishWording() {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "sv_SE"),
            timeZone: TimeZone(identifier: "Europe/Stockholm")!,
            language: .swedish
        )
        let rendered = ctx.render()
        #expect(rendered.contains("Aktuellt datum och tid"))
        #expect(rendered.contains("träningsdata"))
        #expect(rendered.contains("Europe/Stockholm"))
    }

    @Test func differentTimeZonesProduceDifferentLocalTimes() {
        let utc = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        ).render()
        let tokyo = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        ).render()
        // The ISO stamp is the same (it's the same instant), but the
        // human-formatted local time and tz identifier differ.
        #expect(utc != tokyo)
        #expect(utc.contains("GMT"))
        #expect(tokyo.contains("Asia/Tokyo"))
        // Tokyo runs in JST (+09:00) so the printed local clock-time differs.
        #expect(!tokyo.contains("8:26 PM"))
    }

    @Test func renderingNeverThrowsOrReturnsEmpty() {
        let rendered = TemporalContext().render()
        #expect(!rendered.isEmpty)
        #expect(rendered.count > 60)
    }

    // MARK: - renderDayHeader

    @Test func dayHeaderEnglishContainsDateOnly() {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        )
        let header = ctx.renderDayHeader()
        #expect(header.hasPrefix("[Today is "))
        #expect(header.hasSuffix("]"))
        #expect(header.contains("Thursday"))
        #expect(header.contains("2026"))
        // Crucially: NO time, NO ISO timestamp — the whole point.
        #expect(!header.contains(":"))
        #expect(!header.contains("PM"))
        #expect(!header.contains("AM"))
        #expect(!header.contains("Z"))
    }

    @Test func dayHeaderSwedishUsesSwedishWording() {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "sv_SE"),
            timeZone: TimeZone(identifier: "Europe/Stockholm")!,
            language: .swedish
        )
        let header = ctx.renderDayHeader()
        #expect(header.hasPrefix("[Idag är "))
        #expect(header.hasSuffix("]"))
    }

    @Test func dayHeaderStableAcrossSubdayDriftSameDay() {
        // 2026-05-29T08:00:00Z → +6h is 14:00 same day. Asserts the
        // cache-friendliness property we depend on.
        let baseMorning = Date(timeIntervalSince1970: 1_780_041_600) // 2026-05-29T08:00Z
        let morning = TemporalContext(
            date: baseMorning,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        ).renderDayHeader()
        let afternoon = TemporalContext(
            date: baseMorning.addingTimeInterval(6 * 3600),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        ).renderDayHeader()
        #expect(morning == afternoon)
    }

    @Test func dayHeaderDiffersAcrossDays() {
        // Two moments 25 hours apart → different headers.
        let day1 = TemporalContext(
            date: Date(timeIntervalSince1970: 1_780_000_000),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        ).renderDayHeader()
        let day2 = TemporalContext(
            date: Date(timeIntervalSince1970: 1_780_000_000 + 25 * 3600),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        ).renderDayHeader()
        #expect(day1 != day2)
    }

    // MARK: - renderFullJSON

    @Test func fullJSONIsValidParseableJSON() throws {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        )
        let raw = ctx.renderFullJSON()
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String]
        #expect(parsed?["iso8601"] == "2026-05-28T20:26:40Z")
        // Foundation canonicalises "UTC" identifier to "GMT".
        #expect(parsed?["timezone"] == "GMT")
        #expect(parsed?["human"]?.contains("Thursday") == true)
    }

    @Test func fullJSONHonoursTimeZone() throws {
        let ctx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!,
            language: .english
        )
        let raw = ctx.renderFullJSON()
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String]
        #expect(parsed?["timezone"] == "Asia/Tokyo")
        // Tokyo runs +09:00, so the human string for the same instant differs from UTC.
        let utcCtx = TemporalContext(
            date: Self.referenceDate,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!,
            language: .english
        )
        let utcRaw = utcCtx.renderFullJSON()
        let utcParsed = try JSONSerialization.jsonObject(with: Data(utcRaw.utf8)) as? [String: String]
        #expect(parsed?["human"] != utcParsed?["human"])
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import FyxLocalProviders

/// Read + (confirmed) write access to the user's macOS Calendar.
///
/// Reads (`action: "search"`) run immediately. Writes (`create`/`edit`/`delete`)
/// are NEVER applied by the tool: when calendar changes are enabled it stages a
/// `CalendarWriteProposal` (via `stageWrite`) and returns an
/// "awaiting_confirmation" result; the app shows a confirm dialog and commits
/// only on the user's approval. When changes are disabled, a write returns an
/// error. The concrete EventKit access is an injected `CalendarProvider`.
public struct CalendarTool: Tool {
    public let name = "calendar"
    public let provider: any CalendarProvider
    /// Read live per-invocation (the user can toggle "Allow calendar changes").
    public let allowWrites: @Sendable () -> Bool
    /// Push a proposed change to the app for user confirmation.
    public let stageWrite: @Sendable (CalendarWriteProposal) -> Void
    /// Generate a stable proposal id without `UUID()` in the hot path is not
    /// required here — but injected so tests stay deterministic.
    public let makeProposalID: @Sendable () -> String
    public let defaultLimit: Int
    public let maxLimit: Int

    public init(
        provider: any CalendarProvider,
        allowWrites: @escaping @Sendable () -> Bool,
        stageWrite: @escaping @Sendable (CalendarWriteProposal) -> Void,
        makeProposalID: @escaping @Sendable () -> String = { UUID().uuidString },
        defaultLimit: Int = 50,
        maxLimit: Int = 200
    ) {
        self.provider = provider
        self.allowWrites = allowWrites
        self.stageWrite = stageWrite
        self.makeProposalID = makeProposalID
        self.defaultLimit = defaultLimit
        self.maxLimit = maxLimit
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description = PromptStrings.string("tool.calendar.desc", language)
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"action":{"type":"string","enum":["search","create","edit","delete"],"description":"search reads; create/edit/delete are proposed and require user confirmation."},"query":{"type":"string","description":"search: filter events by title/notes/location."},"start":{"type":"string","description":"ISO-8601. search: window start. create/edit: event start."},"end":{"type":"string","description":"ISO-8601. search: window end. create/edit: event end."},"limit":{"type":"integer","minimum":1,"maximum":200,"description":"search: max events (default 50)."},"title":{"type":"string","description":"create/edit: event title."},"location":{"type":"string"},"notes":{"type":"string"},"all_day":{"type":"boolean"},"event_id":{"type":"string","description":"edit/delete: identifier of the target event (from a prior search)."}},"required":["action"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: false)
    }

    private struct Args: Decodable {
        let action: String
        let query: String?
        let start: String?
        let end: String?
        let limit: Int?
        let title: String?
        let location: String?
        let notes: String?
        let all_day: Bool?
        let event_id: String?
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.isEmpty ? "{}" : trimmed
        guard let data = normalised.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Args.self, from: data) else {
            return errorOutput("Could not parse arguments. Got: \(arguments.escapedForJSONInline())")
        }

        // Read access is required for everything (full access covers read+write).
        let access = await provider.authorization()
        guard access == .fullAccess else {
            let reason: String
            switch access {
            case .writeOnly: reason = "Only write-only Calendar access was granted; reading events needs full access. Re-grant in System Settings → Privacy & Security → Calendars."
            case .denied: reason = "Calendar access was denied. Allow it in System Settings → Privacy & Security → Calendars."
            case .restricted: reason = "Calendar access is restricted on this Mac (e.g. by a profile or parental controls)."
            case .notDetermined: reason = "Calendar access has not been granted yet. Enable the Calendar tool in Settings → Tools, then allow the macOS prompt."
            case .fullAccess: reason = ""   // unreachable
            }
            return errorOutput(reason)
        }

        switch parsed.action.lowercased() {
        case "search":
            return await search(parsed)
        case "create", "edit", "delete":
            return await stage(parsed, action: parsed.action.lowercased())
        default:
            return errorOutput("Unknown action '\(parsed.action.escapedForJSONInline())'. Use search, create, edit, or delete.")
        }
    }

    // MARK: - Read

    private func search(_ args: Args) async -> ToolOutput {
        let q = args.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (q?.isEmpty == false) ? q : nil
        let limit = max(1, min(args.limit ?? defaultLimit, maxLimit))
        let start = args.start.flatMap(Self.isoDate)
        let end = args.end.flatMap(Self.isoDate)
        do {
            let events = try await provider.fetch(query: query, start: start, end: end, limit: limit)
            // Pre-format each event's date WITH its weekday so the model reports
            // our (correct) string instead of recomputing the weekday from a raw
            // ISO timestamp — which it does unreliably (e.g. calling 1 June a
            // Sunday when it isn't). `when` is authoritative; `start`/`end` stay
            // ISO for any precise math.
            let dtos = events.map { CalendarEventDTO(from: $0) }
            let payload = SearchPayload(count: dtos.count, events: dtos)
            let json = try JSONEncoder.iso.encode(payload)
            return ToolOutput(outputJSON: String(decoding: json, as: UTF8.self), display: .markdown)
        } catch {
            return errorOutput("calendar search failed: \(error.localizedDescription.escapedForJSONInline())")
        }
    }

    // MARK: - Write (stage only)

    private func stage(_ args: Args, action: String) async -> ToolOutput {
        guard allowWrites() else {
            return errorOutput("Calendar changes are turned off. Enable “Allow calendar changes” in Settings → Tools to let the assistant propose edits (you'll still confirm each one).")
        }
        let op: CalendarWriteProposal.Op
        switch action {
        case "create": op = .create
        case "edit": op = .edit
        default: op = .delete
        }

        // Validate per-op requirements.
        if op == .create {
            guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let startStr = args.start, let start = Self.isoDate(startStr) else {
                return errorOutput("create requires `title` and a valid ISO-8601 `start`.")
            }
            let end = args.end.flatMap(Self.isoDate) ?? start.addingTimeInterval(3600)
            let event = CalendarEvent(
                title: title, start: start, end: end,
                isAllDay: args.all_day ?? false,
                location: args.location, notes: args.notes
            )
            return makeProposal(op: op, event: event, summary: "Create “\(title)” \(Self.range(start, end, event.isAllDay))")
        } else {
            guard let id = args.event_id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return errorOutput("\(action) requires `event_id` (find it first with action=search).")
            }
            // Resolve the real event so the confirmation reads "Delete “Lunch”,
            // Tuesday…" instead of a raw UUID. Falls back to the id only if the
            // event can't be found.
            let existing = await provider.event(id: id)
            let displayTitle = existing?.title ?? args.title ?? "this event"
            if op == .delete {
                let event = existing ?? CalendarEvent(id: id, title: displayTitle, start: .now, end: .now)
                let whenStr = existing.map { " (\(Self.range($0.start, $0.end, $0.isAllDay)))" } ?? ""
                return makeProposal(op: op, event: event, summary: "Delete “\(displayTitle)”\(whenStr)")
            } else {
                // edit: carry whatever fields were provided; the provider applies
                // them, leaving omitted fields untouched.
                let start = args.start.flatMap(Self.isoDate) ?? existing?.start ?? .now
                let end = args.end.flatMap(Self.isoDate) ?? existing?.end ?? start.addingTimeInterval(3600)
                let event = CalendarEvent(
                    id: id,
                    title: args.title ?? existing?.title ?? "",
                    start: start, end: end,
                    isAllDay: args.all_day ?? existing?.isAllDay ?? false,
                    location: args.location, notes: args.notes
                )
                return makeProposal(op: op, event: event, summary: "Edit “\(displayTitle)” → \(Self.range(start, end, event.isAllDay))")
            }
        }
    }

    private func makeProposal(op: CalendarWriteProposal.Op, event: CalendarEvent, summary: String) -> ToolOutput {
        let proposal = CalendarWriteProposal(id: makeProposalID(), op: op, summary: summary, event: event)
        stageWrite(proposal)
        let json = #"{"status":"awaiting_confirmation","summary":"\#(summary.escapedForJSONInline())","note":"The change has been proposed. It will only happen if the user confirms it in the app."}"#
        return ToolOutput(outputJSON: json, display: .markdown)
    }

    // MARK: - Helpers

    /// Parse a model-supplied date. See `FlexibleISODate.parse` — accepts ISO
    /// with/without timezone and plain `yyyy-MM-dd`.
    static func isoDate(_ raw: String) -> Date? { FlexibleISODate.parse(raw) }

    private static func range(_ start: Date, _ end: Date, _ allDay: Bool) -> String {
        // Include the WEEKDAY so a wrong day (the model miscomputing "next
        // Tuesday") is visible in the confirmation before the user approves.
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = allDay ? "EEEE, d MMM yyyy" : "EEEE, d MMM yyyy 'at' HH:mm"
        if allDay { return f.string(from: start) }
        let endF = DateFormatter(); endF.locale = .current; endF.timeZone = .current; endF.dateFormat = "HH:mm"
        return "\(f.string(from: start))–\(endF.string(from: end))"
    }
}

private struct SearchPayload: Encodable {
    let count: Int
    let events: [CalendarEventDTO]
}

/// A returned event with a pre-formatted, weekday-bearing `when` string so the
/// model never recomputes the day of week itself. `start`/`end` stay ISO-8601.
private struct CalendarEventDTO: Encodable {
    let id: String?
    let title: String
    let when: String       // e.g. "Monday, 1 June 2026, 14:00–15:00" (authoritative)
    let weekday: String    // e.g. "Monday"
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let calendar: String?

    init(from e: CalendarEvent) {
        self.id = e.id
        self.title = e.title
        self.start = e.start
        self.end = e.end
        self.isAllDay = e.isAllDay
        self.location = e.location
        self.notes = e.notes
        self.calendar = e.calendar

        let day = DateFormatter(); day.locale = .current; day.timeZone = .current
        day.dateFormat = "EEEE"
        self.weekday = day.string(from: e.start)

        let full = DateFormatter(); full.locale = .current; full.timeZone = .current
        if e.isAllDay {
            full.dateFormat = "EEEE, d MMMM yyyy"
            self.when = "\(full.string(from: e.start)) (all day)"
        } else {
            full.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
            let endF = DateFormatter(); endF.locale = .current; endF.timeZone = .current; endF.dateFormat = "HH:mm"
            self.when = "\(full.string(from: e.start))–\(endF.string(from: e.end))"
        }
    }
}

private extension JSONEncoder {
    /// ISO-8601 dates so the model gets unambiguous timestamps.
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

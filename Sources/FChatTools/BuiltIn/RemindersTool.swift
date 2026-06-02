// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatProviders

/// Read + (confirmed) write access to the user's macOS Reminders.
///
/// Reads (`action: "search"`) run immediately. Writes (`create`/`edit`/`delete`/
/// `complete`) are NEVER applied by the tool: when reminder changes are enabled
/// it stages a `ReminderWriteProposal` (via `stageWrite`) and returns an
/// "awaiting_confirmation" result; the app shows a confirm dialog and commits
/// only on the user's approval. When changes are disabled, a write returns an
/// error. The concrete EventKit access is an injected `ReminderProvider`.
public struct RemindersTool: Tool {
    public let name = "reminders"
    public let provider: any ReminderProvider
    /// Read live per-invocation (the user can toggle "Allow reminder changes").
    public let allowWrites: @Sendable () -> Bool
    /// Push a proposed change to the app for user confirmation.
    public let stageWrite: @Sendable (ReminderWriteProposal) -> Void
    /// Injected so tests stay deterministic.
    public let makeProposalID: @Sendable () -> String
    public let defaultLimit: Int
    public let maxLimit: Int

    public init(
        provider: any ReminderProvider,
        allowWrites: @escaping @Sendable () -> Bool,
        stageWrite: @escaping @Sendable (ReminderWriteProposal) -> Void,
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
        let description: String
        switch language {
        case .english:
            description = "Read the user's macOS Reminders and (when the user has allowed reminder changes) PROPOSE creating, editing, deleting, or completing reminders. `action`: \"search\" reads reminders (immediate); \"create\"/\"edit\"/\"delete\"/\"complete\" do NOT take effect immediately — they are proposed and the user must confirm each change in the app before it happens. For edit/delete/complete, pass the `reminder_id` of a reminder you found via search. A reminder's due date is optional: provide `due` as `YYYY-MM-DDTHH:MM` for a timed reminder or `YYYY-MM-DD` for a day with no specific time (the user's local time). IMPORTANT: a due time alone does NOT raise an alert — if the user sets a due time, ASK whether they also want an alert/notification at that time, then set `add_alarm` accordingly (do not assume). IMPORTANT for dates: today's date AND weekday are given in the conversation; when the user names a weekday or a relative day (\"tomorrow\", \"next week\"), compute the exact calendar date carefully and double-check the weekday before proposing. `priority`: 0 none, 1 high, 5 medium, 9 low."
        case .swedish:
            description = "Läs användarens macOS-påminnelser och (när användaren tillåtit påminnelseändringar) FÖRESLÅ att skapa, ändra, ta bort eller slutföra påminnelser. `action`: \"search\" läser påminnelser (omedelbart); \"create\"/\"edit\"/\"delete\"/\"complete\" träder INTE i kraft direkt — de föreslås och användaren måste bekräfta varje ändring i appen först. För edit/delete/complete, ange `reminder_id` för en påminnelse du hittat via sökning. Förfallodatum är valfritt: ange `due` som `ÅÅÅÅ-MM-DDTHH:MM` för en tidsbestämd påminnelse eller `ÅÅÅÅ-MM-DD` för en dag utan särskild tid (användarens lokala tid). VIKTIGT: en förfallotid ger INTE ett larm i sig — om användaren anger en tid, FRÅGA om de även vill ha ett larm/avisering vid den tiden och sätt `add_alarm` därefter (anta inte). VIKTIGT om datum: dagens datum OCH veckodag finns i konversationen; när användaren nämner en veckodag eller en relativ dag (\"imorgon\", \"nästa vecka\"), beräkna exakt datum noggrant och dubbelkolla veckodagen innan du föreslår. `priority`: 0 ingen, 1 hög, 5 medel, 9 låg."
        case .danish:
            description = "Læs brugerens macOS-påmindelser og (når brugeren har tilladt påmindelsesændringer) FORESLÅ at oprette, ændre, slette eller fuldføre påmindelser. `action`: \"search\" læser påmindelser (med det samme); \"create\"/\"edit\"/\"delete\"/\"complete\" træder IKKE i kraft med det samme — de foreslås, og brugeren skal bekræfte hver ændring i appen først. Til edit/delete/complete angives `reminder_id` for en påmindelse, du har fundet via søgning. Forfaldsdato er valgfri: angiv `due` som `ÅÅÅÅ-MM-DDTHH:MM` for en tidsbestemt påmindelse eller `ÅÅÅÅ-MM-DD` for en dag uden et bestemt tidspunkt (brugerens lokale tid). VIGTIGT: et forfaldstidspunkt udløser IKKE en alarm i sig selv — hvis brugeren angiver et tidspunkt, så SPØRG, om de også vil have en alarm/notifikation på det tidspunkt, og sæt `add_alarm` derefter (antag det ikke). VIGTIGT om datoer: dagens dato OG ugedag står i samtalen; når brugeren nævner en ugedag eller en relativ dag (\"i morgen\", \"i næste uge\"), så beregn den nøjagtige dato omhyggeligt, og dobbelttjek ugedagen, før du foreslår. `priority`: 0 ingen, 1 høj, 5 mellem, 9 lav."
        }
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"action":{"type":"string","enum":["search","create","edit","delete","complete"],"description":"search reads; create/edit/delete/complete are proposed and require user confirmation."},"query":{"type":"string","description":"search: filter reminders by title/notes."},"include_completed":{"type":"boolean","description":"search: also return completed reminders (default false = incomplete only)."},"limit":{"type":"integer","minimum":1,"maximum":200,"description":"search: max reminders (default 50)."},"title":{"type":"string","description":"create/edit: reminder title."},"notes":{"type":"string","description":"create/edit: reminder notes."},"due":{"type":"string","description":"create/edit: due date. YYYY-MM-DDTHH:MM for a time, or YYYY-MM-DD for a whole day."},"priority":{"type":"integer","minimum":0,"maximum":9,"description":"create/edit: 0 none, 1 high, 5 medium, 9 low."},"add_alarm":{"type":"boolean","description":"create/edit: attach an alert at the due time (ask the user first)."},"reminder_id":{"type":"string","description":"edit/delete/complete: identifier of the target reminder (from a prior search)."}},"required":["action"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: false)
    }

    private struct Args: Decodable {
        let action: String
        let query: String?
        let include_completed: Bool?
        let limit: Int?
        let title: String?
        let notes: String?
        let due: String?
        let priority: Int?
        let add_alarm: Bool?
        let reminder_id: String?
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
            case .denied: reason = "Reminders access was denied. Allow it in System Settings → Privacy & Security → Reminders."
            case .restricted: reason = "Reminders access is restricted on this Mac (e.g. by a profile or parental controls)."
            case .notDetermined: reason = "Reminders access has not been granted yet. Enable the Reminders tool in Settings → Tools, then allow the macOS prompt."
            case .fullAccess: reason = ""   // unreachable
            }
            return errorOutput(reason)
        }

        switch parsed.action.lowercased() {
        case "search":
            return await search(parsed)
        case "create", "edit", "delete", "complete":
            return await stage(parsed, action: parsed.action.lowercased())
        default:
            return errorOutput("Unknown action '\(parsed.action.escapedForJSONInline())'. Use search, create, edit, delete, or complete.")
        }
    }

    // MARK: - Read

    private func search(_ args: Args) async -> ToolOutput {
        let q = args.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (q?.isEmpty == false) ? q : nil
        let limit = max(1, min(args.limit ?? defaultLimit, maxLimit))
        do {
            let reminders = try await provider.fetch(
                query: query,
                includeCompleted: args.include_completed ?? false,
                limit: limit
            )
            // Pre-format each due date WITH its weekday so the model reports our
            // (correct) string instead of recomputing the weekday from a raw ISO
            // timestamp — which it does unreliably. `when` is authoritative.
            let dtos = reminders.map { ReminderDTO(from: $0) }
            let payload = SearchPayload(count: dtos.count, reminders: dtos)
            let json = try JSONEncoder.iso.encode(payload)
            return ToolOutput(outputJSON: String(decoding: json, as: UTF8.self), display: .markdown)
        } catch {
            return errorOutput("reminders search failed: \(error.localizedDescription.escapedForJSONInline())")
        }
    }

    // MARK: - Write (stage only)

    private func stage(_ args: Args, action: String) async -> ToolOutput {
        guard allowWrites() else {
            return errorOutput("Reminder changes are turned off. Enable “Allow reminder changes” in Settings → Tools to let the assistant propose edits (you'll still confirm each one).")
        }
        let op: ReminderWriteProposal.Op
        switch action {
        case "create": op = .create
        case "edit": op = .edit
        case "complete": op = .complete
        default: op = .delete
        }

        if op == .create {
            guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return errorOutput("create requires a `title`.")
            }
            let (due, hasTime) = Self.parseDue(args.due)
            let addAlarm = (args.add_alarm ?? false) && hasTime
            let reminder = Reminder(
                title: title, notes: args.notes,
                due: due, hasTime: hasTime,
                priority: args.priority ?? 0,
                hasAlarm: addAlarm
            )
            return makeProposal(op: op, reminder: reminder, addAlarm: addAlarm,
                                summary: "Create “\(title)”\(Self.dueSuffix(due, hasTime, addAlarm))")
        } else {
            guard let id = args.reminder_id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return errorOutput("\(action) requires `reminder_id` (find it first with action=search).")
            }
            // Resolve the real reminder so the confirmation reads "Delete “Call
            // dentist”" instead of a raw id. Falls back to the id otherwise.
            let existing = await provider.reminder(id: id)
            let displayTitle = existing?.title ?? args.title ?? "this reminder"
            switch op {
            case .delete:
                let reminder = existing ?? Reminder(id: id, title: displayTitle)
                return makeProposal(op: op, reminder: reminder, addAlarm: false,
                                    summary: "Delete “\(displayTitle)”")
            case .complete:
                let reminder = existing ?? Reminder(id: id, title: displayTitle)
                return makeProposal(op: op, reminder: reminder, addAlarm: false,
                                    summary: "Mark “\(displayTitle)” done")
            default: // edit
                let (parsedDue, parsedHasTime) = Self.parseDue(args.due)
                let due = args.due != nil ? parsedDue : existing?.due
                let hasTime = args.due != nil ? parsedHasTime : (existing?.hasTime ?? false)
                let addAlarm = (args.add_alarm ?? existing?.hasAlarm ?? false) && hasTime
                let reminder = Reminder(
                    id: id,
                    title: args.title ?? existing?.title ?? "",
                    notes: args.notes ?? existing?.notes,
                    due: due, hasTime: hasTime,
                    priority: args.priority ?? existing?.priority ?? 0,
                    hasAlarm: addAlarm
                )
                return makeProposal(op: op, reminder: reminder, addAlarm: addAlarm,
                                    summary: "Edit “\(displayTitle)”\(Self.dueSuffix(due, hasTime, addAlarm))")
            }
        }
    }

    private func makeProposal(op: ReminderWriteProposal.Op, reminder: Reminder, addAlarm: Bool, summary: String) -> ToolOutput {
        let proposal = ReminderWriteProposal(id: makeProposalID(), op: op, summary: summary, reminder: reminder, addAlarm: addAlarm)
        stageWrite(proposal)
        let json = #"{"status":"awaiting_confirmation","summary":"\#(summary.escapedForJSONInline())","note":"The change has been proposed. It will only happen if the user confirms it in the app."}"#
        return ToolOutput(outputJSON: json, display: .markdown)
    }

    // MARK: - Helpers

    /// Parse a due date the model supplied, returning the instant and whether it
    /// carries a time of day. A plain `yyyy-MM-dd` is a whole-day reminder
    /// (hasTime=false); anything with a time component is timed (hasTime=true).
    static func parseDue(_ raw: String?) -> (Date?, Bool) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return (nil, false) }
        guard let date = isoDate(raw) else { return (nil, false) }
        // Date-only forms have no 'T'/':' — treat as whole-day (no specific time).
        let hasTime = raw.contains(":")
        return (date, hasTime)
    }

    /// Parse a model-supplied date. See `FlexibleISODate.parse` — accepts ISO
    /// with/without timezone and plain `yyyy-MM-dd`.
    static func isoDate(_ raw: String) -> Date? { FlexibleISODate.parse(raw) }

    /// Human-readable " — due …" suffix (with weekday) for a confirmation summary.
    private static func dueSuffix(_ due: Date?, _ hasTime: Bool, _ alarm: Bool) -> String {
        guard let due else { return "" }
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = hasTime ? "EEEE, d MMM yyyy 'at' HH:mm" : "EEEE, d MMM yyyy"
        let alarmStr = alarm ? " (with alert)" : ""
        return " — due \(f.string(from: due))\(alarmStr)"
    }
}

private struct SearchPayload: Encodable {
    let count: Int
    let reminders: [ReminderDTO]
}

/// A returned reminder with a pre-formatted, weekday-bearing `when` string so the
/// model never recomputes the day of week itself. `due` stays ISO-8601.
private struct ReminderDTO: Encodable {
    let id: String?
    let title: String
    let when: String?      // e.g. "Monday, 1 June 2026 at 14:00" — nil if no due date
    let weekday: String?   // e.g. "Monday" — nil if no due date
    let due: Date?
    let hasTime: Bool
    let isCompleted: Bool
    let priority: Int
    let hasAlarm: Bool
    let notes: String?
    let list: String?

    init(from r: Reminder) {
        self.id = r.id
        self.title = r.title
        self.due = r.due
        self.hasTime = r.hasTime
        self.isCompleted = r.isCompleted
        self.priority = r.priority
        self.hasAlarm = r.hasAlarm
        self.notes = r.notes
        self.list = r.list

        if let due = r.due {
            let day = DateFormatter(); day.locale = .current; day.timeZone = .current
            day.dateFormat = "EEEE"
            self.weekday = day.string(from: due)

            let full = DateFormatter(); full.locale = .current; full.timeZone = .current
            full.dateFormat = r.hasTime ? "EEEE, d MMMM yyyy 'at' HH:mm" : "EEEE, d MMMM yyyy"
            self.when = full.string(from: due)
        } else {
            self.weekday = nil
            self.when = nil
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

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// One reminder, flattened to Sendable values. The platform `EKReminder` is
/// mapped to this in the app layer so `FChatTools` never imports EventKit.
/// Reminders differ from events: the due date is a single optional instant
/// (events have start+end), and there is a completion state and a priority.
public struct Reminder: Sendable, Hashable, Codable {
    public var id: String?          // EKReminder.calendarItemIdentifier — nil for a not-yet-created reminder
    public var title: String
    public var notes: String?
    public var due: Date?           // resolved absolute due instant (nil = no due date)
    public var hasTime: Bool        // false = date-only (no specific time of day)
    public var isCompleted: Bool
    public var priority: Int        // 0 none, 1 high, 5 medium, 9 low (EventKit/CalDAV scale)
    public var hasAlarm: Bool       // whether an alert is attached at the due time
    public var list: String?        // reminder list (EKCalendar) title

    public init(
        id: String? = nil,
        title: String,
        notes: String? = nil,
        due: Date? = nil,
        hasTime: Bool = false,
        isCompleted: Bool = false,
        priority: Int = 0,
        hasAlarm: Bool = false,
        list: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.due = due
        self.hasTime = hasTime
        self.isCompleted = isCompleted
        self.priority = priority
        self.hasAlarm = hasAlarm
        self.list = list
    }
}

/// Reminder authorization tiers. Unlike Calendar, Reminders has no write-only
/// mode — access is all-or-nothing (full) once granted.
public enum ReminderAccess: Sendable, Equatable {
    case fullAccess   // read + write
    case denied
    case restricted
    case notDetermined
}

/// A proposed reminder change the user must confirm before it commits. Carries
/// everything needed to describe the change and to commit it on approval.
public struct ReminderWriteProposal: Sendable, Hashable, Codable, Identifiable {
    public enum Op: String, Sendable, Codable { case create, edit, delete, complete }

    public var id: String           // stable proposal id
    public var op: Op
    public var summary: String      // human-readable, e.g. "Create “Call dentist” — due Tue 3 Jun at 15:00 (with alert)"
    public var reminder: Reminder   // new reminder (create) or target (edit/delete/complete, identified by reminder.id)
    public var addAlarm: Bool       // create/edit: attach an alarm at the due time

    public init(id: String, op: Op, summary: String, reminder: Reminder, addAlarm: Bool = false) {
        self.id = id
        self.op = op
        self.summary = summary
        self.reminder = reminder
        self.addAlarm = addAlarm
    }
}

/// Abstraction over the macOS Reminders store. The concrete `EKEventStore`-backed
/// implementation is injected from the app layer (mirrors `CalendarProvider`).
/// Reads are immediate; writes are performed by `commit(_:)` ONLY after the user
/// confirms a staged `ReminderWriteProposal` — the tool itself never writes.
public protocol ReminderProvider: Sendable {
    func authorization() async -> ReminderAccess
    /// Trigger the system permission prompt (full access) when `notDetermined`.
    func requestAccess() async -> ReminderAccess
    /// Read reminders. `query` filters title/notes in-memory; `includeCompleted`
    /// also returns completed reminders (default: incomplete only); `limit` caps.
    func fetch(query: String?, includeCompleted: Bool, limit: Int) async throws -> [Reminder]
    /// Look up a single reminder by identifier (for human-readable
    /// edit/delete/complete confirmations). nil if not found / no access.
    func reminder(id: String) async -> Reminder?
    /// Apply a user-confirmed write. Throws on failure (no access, missing reminder…).
    func commit(_ proposal: ReminderWriteProposal) async throws
}

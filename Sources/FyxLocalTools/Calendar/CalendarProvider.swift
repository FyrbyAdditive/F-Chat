// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// One calendar event, flattened to Sendable values. The platform `EKEvent` is
/// mapped to this in the app layer so `FyxLocalTools` never imports EventKit.
public struct CalendarEvent: Sendable, Hashable, Codable {
    public var id: String?          // EKEvent.eventIdentifier — nil for a not-yet-created event
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var calendar: String?    // calendar title

    public init(
        id: String? = nil,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        calendar: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendar = calendar
    }
}

/// Calendar authorization tiers (macOS 14+ split: full read+write vs write-only).
public enum CalendarAccess: Sendable, Equatable {
    case fullAccess   // read + write
    case writeOnly    // create-only, cannot read
    case denied
    case restricted
    case notDetermined
}

/// A proposed calendar change the user must confirm before it commits. Carries
/// everything needed to describe the change and to commit it on approval.
public struct CalendarWriteProposal: Sendable, Hashable, Codable, Identifiable {
    public enum Op: String, Sendable, Codable { case create, edit, delete }

    public var id: String           // stable proposal id
    public var op: Op
    public var summary: String      // human-readable, e.g. "Create “Lunch” Fri 12:00–13:00"
    public var event: CalendarEvent // new event (create) or target (edit/delete, identified by event.id)

    public init(id: String, op: Op, summary: String, event: CalendarEvent) {
        self.id = id
        self.op = op
        self.summary = summary
        self.event = event
    }
}

/// Abstraction over the macOS Calendar store. The concrete `EKEventStore`-backed
/// implementation is injected from the app layer (mirrors `ContactsProvider`).
/// Reads are immediate; writes are performed by `commit(_:)` ONLY after the user
/// confirms a staged `CalendarWriteProposal` — the tool itself never writes.
public protocol CalendarProvider: Sendable {
    func authorization() async -> CalendarAccess
    /// Trigger the system permission prompt (full access) when `notDetermined`.
    func requestAccess() async -> CalendarAccess
    /// Read events. `query` filters title/notes/location in-memory; `start`/`end`
    /// bound the window (defaults applied by the implementation); `limit` caps.
    func fetch(query: String?, start: Date?, end: Date?, limit: Int) async throws -> [CalendarEvent]
    /// Look up a single event by identifier (for human-readable edit/delete
    /// confirmations). nil if not found / no access.
    func event(id: String) async -> CalendarEvent?
    /// Apply a user-confirmed write. Throws on failure (no access, missing event…).
    func commit(_ proposal: CalendarWriteProposal) async throws
}

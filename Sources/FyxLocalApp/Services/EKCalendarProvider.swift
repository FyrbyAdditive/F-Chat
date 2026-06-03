// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalTools
#if canImport(EventKit)
import EventKit
#endif

/// `EKEventStore`-backed implementation of `CalendarProvider`, in the app layer
/// so `FyxLocalTools` never imports EventKit. All store access is on the main actor
/// (EKEventStore isn't thread-safe); events are mapped to the Sendable
/// `CalendarEvent` before crossing back out.
///
/// Uses the modern macOS 14+ async API (`requestFullAccessToEvents()`), not the
/// deprecated `requestAccess(to:)`. Reading needs full access; writes are applied
/// by `commit(_:)` only after the user confirms a staged proposal in the UI.
/// Requires `com.apple.security.personal-information.calendars` under the hardened
/// runtime + `NSCalendarsFullAccessUsageDescription`.
final class EKCalendarProvider: CalendarProvider {
#if canImport(EventKit)
    enum CalError: Error, CustomStringConvertible {
        case eventNotFound(String)
        case noDefaultCalendar
        var description: String {
            switch self {
            case .eventNotFound(let id): return "no event with id \(id)"
            case .noDefaultCalendar: return "no default calendar to add the event to"
            }
        }
    }

    func authorization() async -> CalendarAccess {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarAccess {
        let current = EKEventStore.authorizationStatus(for: .event)
        guard current == .notDetermined else { return Self.map(current) }
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToEvents()
        return Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    @MainActor
    func fetch(query: String?, start: Date?, end: Date?, limit: Int) async throws -> [CalendarEvent] {
        let store = EKEventStore()
        let from = start ?? Date()
        let to = end ?? from.addingTimeInterval(30 * 24 * 3600)   // default: 30-day window
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        var events = store.events(matching: predicate)
        if let q = query?.lowercased(), !q.isEmpty {
            events = events.filter {
                $0.title.lowercased().contains(q)
                    || ($0.notes?.lowercased().contains(q) ?? false)
                    || ($0.location?.lowercased().contains(q) ?? false)
            }
        }
        return events.prefix(limit).map(Self.record(from:))
    }

    @MainActor
    func event(id: String) async -> CalendarEvent? {
        let store = EKEventStore()
        guard let e = store.event(withIdentifier: id) else { return nil }
        return Self.record(from: e)
    }

    @MainActor
    func commit(_ proposal: CalendarWriteProposal) async throws {
        let store = EKEventStore()
        switch proposal.op {
        case .create:
            let event = EKEvent(eventStore: store)
            apply(proposal.event, to: event)
            guard let cal = store.defaultCalendarForNewEvents else { throw CalError.noDefaultCalendar }
            event.calendar = cal
            try store.save(event, span: .thisEvent, commit: true)
        case .edit:
            guard let id = proposal.event.id, let event = store.event(withIdentifier: id) else {
                throw CalError.eventNotFound(proposal.event.id ?? "(nil)")
            }
            apply(proposal.event, to: event, editing: true)
            try store.save(event, span: .thisEvent, commit: true)
        case .delete:
            guard let id = proposal.event.id, let event = store.event(withIdentifier: id) else {
                throw CalError.eventNotFound(proposal.event.id ?? "(nil)")
            }
            try store.remove(event, span: .thisEvent, commit: true)
        }
    }

    // MARK: - Mapping

    /// Apply proposal fields onto an EKEvent. When `editing`, only non-empty
    /// fields overwrite (so an edit that omits a field leaves it untouched).
    private func apply(_ src: CalendarEvent, to event: EKEvent, editing: Bool = false) {
        if !editing || !src.title.isEmpty { event.title = src.title }
        event.startDate = src.start
        event.endDate = src.end
        event.isAllDay = src.isAllDay
        if let loc = src.location, !(editing && loc.isEmpty) { event.location = loc }
        if let notes = src.notes, !(editing && notes.isEmpty) { event.notes = notes }
    }

    private static func map(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func record(from e: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: e.eventIdentifier,
            title: e.title ?? "(untitled)",
            start: e.startDate,
            end: e.endDate,
            isAllDay: e.isAllDay,
            location: e.location,
            notes: e.notes,
            calendar: e.calendar?.title
        )
    }
#else
    func authorization() async -> CalendarAccess { .restricted }
    func requestAccess() async -> CalendarAccess { .restricted }
    func fetch(query: String?, start: Date?, end: Date?, limit: Int) async throws -> [CalendarEvent] { [] }
    func event(id: String) async -> CalendarEvent? { nil }
    func commit(_ proposal: CalendarWriteProposal) async throws {}
#endif
}

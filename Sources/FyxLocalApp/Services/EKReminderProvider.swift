// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalTools
#if canImport(EventKit)
import EventKit
#endif

/// `EKEventStore`-backed implementation of `ReminderProvider`, in the app layer
/// so `FyxLocalTools` never imports EventKit. All store access is on the main actor
/// (EKEventStore isn't thread-safe); reminders are mapped to the Sendable
/// `Reminder` before crossing back out.
///
/// Uses the modern macOS 14+ async API (`requestFullAccessToReminders()`).
/// Reminders differ from events: fetching is async-via-callback (wrapped in a
/// continuation), the due date is `dueDateComponents` (not start/end), and
/// `save`/`remove` take no `span:`. Requires
/// `com.apple.security.personal-information.reminders` under the hardened runtime
/// + `NSRemindersFullAccessUsageDescription`.
final class EKReminderProvider: ReminderProvider {
#if canImport(EventKit)
    enum RemError: Error, CustomStringConvertible {
        case reminderNotFound(String)
        case noDefaultList
        var description: String {
            switch self {
            case .reminderNotFound(let id): return "no reminder with id \(id)"
            case .noDefaultList: return "no default list to add the reminder to"
            }
        }
    }

    func authorization() async -> ReminderAccess {
        Self.map(EKEventStore.authorizationStatus(for: .reminder))
    }

    func requestAccess() async -> ReminderAccess {
        let current = EKEventStore.authorizationStatus(for: .reminder)
        guard current == .notDetermined else { return Self.map(current) }
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToReminders()
        return Self.map(EKEventStore.authorizationStatus(for: .reminder))
    }

    @MainActor
    func fetch(query: String?, includeCompleted: Bool, limit: Int) async throws -> [Reminder] {
        let store = EKEventStore()
        var collected: [Reminder] = []

        // Incomplete reminders (the default view).
        let incompletePredicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        collected += await Self.fetchReminders(store, matching: incompletePredicate)

        // Optionally also completed reminders.
        if includeCompleted {
            let completePredicate = store.predicateForCompletedReminders(
                withCompletionDateStarting: nil, ending: nil, calendars: nil
            )
            collected += await Self.fetchReminders(store, matching: completePredicate)
        }

        if let q = query?.lowercased(), !q.isEmpty {
            collected = collected.filter {
                $0.title.lowercased().contains(q) || ($0.notes?.lowercased().contains(q) ?? false)
            }
        }

        // Incomplete first, then by due date (no-due last), then title.
        let sorted = collected.sorted { a, b in
            if a.isCompleted != b.isCompleted { return !a.isCompleted }
            switch (a.due, b.due) {
            case let (.some(x), .some(y)) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
        return Array(sorted.prefix(limit))
    }

    @MainActor
    func reminder(id: String) async -> Reminder? {
        let store = EKEventStore()
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return Self.record(from: r)
    }

    @MainActor
    func commit(_ proposal: ReminderWriteProposal) async throws {
        let store = EKEventStore()
        switch proposal.op {
        case .create:
            let reminder = EKReminder(eventStore: store)
            guard let list = store.defaultCalendarForNewReminders() else { throw RemError.noDefaultList }
            reminder.calendar = list
            apply(proposal.reminder, to: reminder, addAlarm: proposal.addAlarm)
            try store.save(reminder, commit: true)
        case .edit:
            guard let reminder = store.calendarItem(withIdentifier: proposal.reminder.id ?? "") as? EKReminder else {
                throw RemError.reminderNotFound(proposal.reminder.id ?? "(nil)")
            }
            apply(proposal.reminder, to: reminder, addAlarm: proposal.addAlarm, editing: true)
            try store.save(reminder, commit: true)
        case .complete:
            guard let reminder = store.calendarItem(withIdentifier: proposal.reminder.id ?? "") as? EKReminder else {
                throw RemError.reminderNotFound(proposal.reminder.id ?? "(nil)")
            }
            reminder.isCompleted = true
            try store.save(reminder, commit: true)
        case .delete:
            guard let reminder = store.calendarItem(withIdentifier: proposal.reminder.id ?? "") as? EKReminder else {
                throw RemError.reminderNotFound(proposal.reminder.id ?? "(nil)")
            }
            try store.remove(reminder, commit: true)
        }
    }

    // MARK: - Mapping

    /// Apply proposal fields onto an EKReminder. When `editing`, only provided/
    /// non-empty fields overwrite (an edit that omits a field leaves it untouched).
    private func apply(_ src: Reminder, to reminder: EKReminder, addAlarm: Bool, editing: Bool = false) {
        if !editing || !src.title.isEmpty { reminder.title = src.title }
        if let notes = src.notes, !(editing && notes.isEmpty) { reminder.notes = notes }
        reminder.priority = src.priority

        // Due date → DateComponents (date-only when hasTime is false).
        if let due = src.due {
            let cal = Calendar.current
            let comps: Set<Calendar.Component> = src.hasTime
                ? [.year, .month, .day, .hour, .minute]
                : [.year, .month, .day]
            reminder.dueDateComponents = cal.dateComponents(comps, from: due)
        } else if !editing {
            reminder.dueDateComponents = nil
        }

        // Alarms: replace any existing alarms with a single absolute-date alarm at
        // the due time when requested; otherwise clear (for a timed due date).
        if let existing = reminder.alarms { existing.forEach(reminder.removeAlarm) }
        if addAlarm, src.hasTime, let due = src.due {
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> ReminderAccess {
        switch status {
        case .fullAccess: return .fullAccess
        case .writeOnly: return .fullAccess   // reminders have no write-only mode; treat as full
        case .authorized: return .fullAccess  // legacy pre-14 status
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Wrap the callback-based `fetchReminders` in a continuation, mapping to the
    /// Sendable `Reminder` INSIDE the closure so no `EKReminder` (non-Sendable)
    /// crosses the continuation boundary. The callback may run off the main
    /// thread; the array is optional (nil on failure).
    private static func fetchReminders(_ store: EKEventStore, matching predicate: NSPredicate) async -> [Reminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.record(from:)))
            }
        }
    }

    /// Resolve a reminder's due components to an absolute instant (for sorting).
    private static func dueInstant(_ comps: DateComponents?) -> Date? {
        guard let comps else { return nil }
        return Calendar.current.date(from: comps)
    }

    private static func record(from r: EKReminder) -> Reminder {
        let comps = r.dueDateComponents
        let due = dueInstant(comps)
        // hasTime when the due components carry an hour (date-only reminders don't).
        let hasTime = comps?.hour != nil
        return Reminder(
            id: r.calendarItemIdentifier,
            title: r.title ?? "(untitled)",
            notes: r.notes,
            due: due,
            hasTime: hasTime,
            isCompleted: r.isCompleted,
            priority: r.priority,
            hasAlarm: !(r.alarms?.isEmpty ?? true),
            list: r.calendar?.title
        )
    }
#else
    func authorization() async -> ReminderAccess { .restricted }
    func requestAccess() async -> ReminderAccess { .restricted }
    func fetch(query: String?, includeCompleted: Bool, limit: Int) async throws -> [Reminder] { [] }
    func reminder(id: String) async -> Reminder? { nil }
    func commit(_ proposal: ReminderWriteProposal) async throws {}
#endif
}

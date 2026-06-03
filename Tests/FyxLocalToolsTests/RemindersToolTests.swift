// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalTools

@Suite("RemindersTool")
struct RemindersToolTests {

    /// Stub provider recording calls. Mirrors StubCalendar.
    actor StubReminders: ReminderProvider {
        let access: ReminderAccess
        let pool: [Reminder]
        private(set) var fetchCalls = 0
        private(set) var commitCalls = 0
        private(set) var lastLimit: Int?
        private(set) var lastIncludeCompleted: Bool?
        private(set) var lastCommitted: ReminderWriteProposal?

        init(access: ReminderAccess, pool: [Reminder] = []) {
            self.access = access
            self.pool = pool
        }
        func authorization() async -> ReminderAccess { access }
        func requestAccess() async -> ReminderAccess { access }
        func fetch(query: String?, includeCompleted: Bool, limit: Int) async throws -> [Reminder] {
            fetchCalls += 1
            lastLimit = limit
            lastIncludeCompleted = includeCompleted
            var matched = query.map { q in pool.filter { $0.title.localizedCaseInsensitiveContains(q) } } ?? pool
            if !includeCompleted { matched = matched.filter { !$0.isCompleted } }
            return Array(matched.prefix(limit))
        }
        func reminder(id: String) async -> Reminder? { pool.first { $0.id == id } }
        func commit(_ proposal: ReminderWriteProposal) async throws {
            commitCalls += 1
            lastCommitted = proposal
        }
    }

    /// Captures staged proposals (mirrors AppEnvironment.pendingReminderWrite).
    final class Stager: @unchecked Sendable {
        private let lock = NSLock()
        private var _staged: [ReminderWriteProposal] = []
        var staged: [ReminderWriteProposal] { lock.lock(); defer { lock.unlock() }; return _staged }
        func stage(_ p: ReminderWriteProposal) { lock.lock(); _staged.append(p); lock.unlock() }
    }

    private func sample() -> [Reminder] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return [
            Reminder(id: "rem-1", title: "Call dentist", due: now, hasTime: true),
            Reminder(id: "rem-2", title: "Buy milk", isCompleted: false),
            Reminder(id: "rem-3", title: "File taxes", isCompleted: true),
        ]
    }

    private func tool(access: ReminderAccess, writes: Bool, pool: [Reminder] = [], stager: Stager = Stager()) -> (RemindersTool, StubReminders, Stager) {
        let stub = StubReminders(access: access, pool: pool)
        let t = RemindersTool(
            provider: stub,
            allowWrites: { writes },
            stageWrite: { stager.stage($0) },
            makeProposalID: { "fixed-id" }
        )
        return (t, stub, stager)
    }

    @Test func searchReturnsIncompleteWhenAuthorized() async throws {
        let (t, stub, _) = tool(access: .fullAccess, writes: false, pool: sample())
        let out = try await t.invoke(arguments: #"{"action":"search"}"#)
        #expect(out.isError == false)
        let obj = try JSONSerialization.jsonObject(with: Data(out.outputJSON.utf8)) as? [String: Any]
        #expect((obj?["count"] as? Int) == 2)   // incomplete only (rem-1, rem-2)
        #expect(await stub.fetchCalls == 1)
        #expect(await stub.lastIncludeCompleted == false)
    }

    @Test func searchIncludeCompletedReturnsAll() async throws {
        let (t, stub, _) = tool(access: .fullAccess, writes: false, pool: sample())
        let out = try await t.invoke(arguments: #"{"action":"search","include_completed":true}"#)
        #expect(out.isError == false)
        let obj = try JSONSerialization.jsonObject(with: Data(out.outputJSON.utf8)) as? [String: Any]
        #expect((obj?["count"] as? Int) == 3)
        #expect(await stub.lastIncludeCompleted == true)
    }

    @Test func notAuthorizedReturnsErrorNoFetch() async throws {
        let (t, stub, _) = tool(access: .notDetermined, writes: true, pool: sample())
        let out = try await t.invoke(arguments: #"{"action":"search"}"#)
        #expect(out.isError == true)
        #expect(await stub.fetchCalls == 0)
    }

    @Test func writeBlockedWhenWritesDisabled() async throws {
        let (t, stub, stager) = tool(access: .fullAccess, writes: false)
        let out = try await t.invoke(arguments: #"{"action":"create","title":"Call dentist"}"#)
        #expect(out.isError == true)
        #expect(stager.staged.isEmpty)          // nothing staged
        #expect(await stub.commitCalls == 0)    // nothing committed
    }

    @Test func createStagesProposalAndDoesNotCommit() async throws {
        let (t, stub, stager) = tool(access: .fullAccess, writes: true)
        let out = try await t.invoke(arguments: #"{"action":"create","title":"Call dentist","due":"2026-06-03T15:00"}"#)
        #expect(out.isError == false)
        #expect(out.outputJSON.contains("awaiting_confirmation"))
        #expect(stager.staged.count == 1)
        #expect(stager.staged.first?.op == .create)
        #expect(stager.staged.first?.reminder.title == "Call dentist")
        #expect(stager.staged.first?.reminder.hasTime == true)
        #expect(await stub.commitCalls == 0)
    }

    @Test func createRequiresTitle() async throws {
        let (t, _, stager) = tool(access: .fullAccess, writes: true)
        let out = try await t.invoke(arguments: #"{"action":"create"}"#)
        #expect(out.isError == true)
        #expect(stager.staged.isEmpty)
    }

    @Test func editDeleteCompleteRequireReminderID() async throws {
        let (t, _, stager) = tool(access: .fullAccess, writes: true)
        let edit = try await t.invoke(arguments: #"{"action":"edit","title":"New"}"#)
        #expect(edit.isError == true)
        let del = try await t.invoke(arguments: #"{"action":"delete"}"#)
        #expect(del.isError == true)
        let done = try await t.invoke(arguments: #"{"action":"complete"}"#)
        #expect(done.isError == true)
        #expect(stager.staged.isEmpty)
    }

    @Test func deleteSummaryShowsTitleNotID() async throws {
        let (t, _, stager) = tool(access: .fullAccess, writes: true, pool: sample())
        let out = try await t.invoke(arguments: #"{"action":"delete","reminder_id":"rem-1"}"#)
        #expect(out.isError == false)
        let p = stager.staged.first
        #expect(p?.op == .delete)
        #expect(p?.reminder.id == "rem-1")
        #expect(p?.summary.contains("Call dentist") == true)
        #expect(p?.summary.contains("rem-1") == false)
    }

    @Test func completeStagesCompleteOpWithTitle() async throws {
        let (t, stub, stager) = tool(access: .fullAccess, writes: true, pool: sample())
        let out = try await t.invoke(arguments: #"{"action":"complete","reminder_id":"rem-2"}"#)
        #expect(out.isError == false)
        let p = stager.staged.first
        #expect(p?.op == .complete)
        #expect(p?.summary.contains("Buy milk") == true)
        #expect(await stub.commitCalls == 0)   // staged, not committed
    }

    @Test func addAlarmFlowsIntoProposalOnlyWhenTimed() async throws {
        let (t, _, stager) = tool(access: .fullAccess, writes: true)
        // Timed due + add_alarm → alarm set.
        _ = try await t.invoke(arguments: #"{"action":"create","title":"Standup","due":"2026-06-03T09:00","add_alarm":true}"#)
        #expect(stager.staged.first?.addAlarm == true)
        #expect(stager.staged.first?.reminder.hasAlarm == true)

        // Date-only due + add_alarm → no alarm (no time to alert at).
        let (t2, _, stager2) = tool(access: .fullAccess, writes: true)
        _ = try await t2.invoke(arguments: #"{"action":"create","title":"Birthday","due":"2026-06-03","add_alarm":true}"#)
        #expect(stager2.staged.first?.addAlarm == false)
    }

    @Test func limitClampedToMax() async throws {
        let (t, stub, _) = tool(access: .fullAccess, writes: false, pool: sample())
        _ = try await t.invoke(arguments: #"{"action":"search","limit":99999}"#)
        #expect(await stub.lastLimit == 200)
    }

    @Test func malformedArgsReturnError() async throws {
        let (t, _, _) = tool(access: .fullAccess, writes: true)
        let out = try await t.invoke(arguments: #"{"action":123}"#)
        #expect(out.isError == true)
    }

    @Test func unknownActionErrors() async throws {
        let (t, _, _) = tool(access: .fullAccess, writes: true)
        let out = try await t.invoke(arguments: #"{"action":"nuke"}"#)
        #expect(out.isError == true)
    }
}

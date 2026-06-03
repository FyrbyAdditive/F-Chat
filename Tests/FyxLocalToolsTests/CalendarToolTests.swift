// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalTools

@Suite("CalendarTool")
struct CalendarToolTests {

    /// Stub provider recording calls. Mirrors StubContacts.
    actor StubCalendar: CalendarProvider {
        let access: CalendarAccess
        let pool: [CalendarEvent]
        private(set) var fetchCalls = 0
        private(set) var commitCalls = 0
        private(set) var lastLimit: Int?
        private(set) var lastCommitted: CalendarWriteProposal?

        init(access: CalendarAccess, pool: [CalendarEvent] = []) {
            self.access = access
            self.pool = pool
        }
        func authorization() async -> CalendarAccess { access }
        func requestAccess() async -> CalendarAccess { access }
        func fetch(query: String?, start: Date?, end: Date?, limit: Int) async throws -> [CalendarEvent] {
            fetchCalls += 1
            lastLimit = limit
            let matched = query.map { q in pool.filter { $0.title.localizedCaseInsensitiveContains(q) } } ?? pool
            return Array(matched.prefix(limit))
        }
        func event(id: String) async -> CalendarEvent? { pool.first { $0.id == id } }
        func commit(_ proposal: CalendarWriteProposal) async throws {
            commitCalls += 1
            lastCommitted = proposal
        }
    }

    /// Captures staged proposals (mirrors what AppEnvironment.pendingCalendarWrite does).
    final class Stager: @unchecked Sendable {
        private let lock = NSLock()
        private var _staged: [CalendarWriteProposal] = []
        var staged: [CalendarWriteProposal] { lock.lock(); defer { lock.unlock() }; return _staged }
        func stage(_ p: CalendarWriteProposal) { lock.lock(); _staged.append(p); lock.unlock() }
    }

    private func sample() -> [CalendarEvent] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return [
            CalendarEvent(id: "evt-1", title: "Standup", start: now, end: now.addingTimeInterval(1800)),
            CalendarEvent(id: "evt-2", title: "Lunch", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(10800)),
        ]
    }

    private func tool(access: CalendarAccess, writes: Bool, pool: [CalendarEvent] = [], stager: Stager = Stager()) -> (CalendarTool, StubCalendar, Stager) {
        let stub = StubCalendar(access: access, pool: pool)
        let t = CalendarTool(
            provider: stub,
            allowWrites: { writes },
            stageWrite: { stager.stage($0) },
            makeProposalID: { "fixed-id" }
        )
        return (t, stub, stager)
    }

    @Test func searchReturnsEventsWhenAuthorized() async throws {
        let (t, stub, _) = tool(access: .fullAccess, writes: false, pool: sample())
        let out = try await t.invoke(arguments: #"{"action":"search"}"#)
        #expect(out.isError == false)
        let obj = try JSONSerialization.jsonObject(with: Data(out.outputJSON.utf8)) as? [String: Any]
        #expect((obj?["count"] as? Int) == 2)
        #expect(await stub.fetchCalls == 1)
    }

    @Test func notAuthorizedReturnsErrorNoFetch() async throws {
        let (t, stub, _) = tool(access: .notDetermined, writes: true, pool: sample())
        let out = try await t.invoke(arguments: #"{"action":"search"}"#)
        #expect(out.isError == true)
        #expect(await stub.fetchCalls == 0)
    }

    @Test func writeOnlyAccessCannotReadOrWrite() async throws {
        // writeOnly is not fullAccess → the tool requires full access to operate.
        let (t, _, _) = tool(access: .writeOnly, writes: true)
        let out = try await t.invoke(arguments: #"{"action":"create","title":"X","start":"2026-01-01T10:00:00Z"}"#)
        #expect(out.isError == true)
    }

    @Test func writeBlockedWhenWritesDisabled() async throws {
        let (t, stub, stager) = tool(access: .fullAccess, writes: false)
        let out = try await t.invoke(arguments: #"{"action":"create","title":"Lunch","start":"2026-01-01T12:00:00Z"}"#)
        #expect(out.isError == true)
        #expect(stager.staged.isEmpty)          // nothing staged
        #expect(await stub.commitCalls == 0)    // nothing committed
    }

    @Test func writeStagesProposalAndDoesNotCommit() async throws {
        let (t, stub, stager) = tool(access: .fullAccess, writes: true)
        let out = try await t.invoke(arguments: #"{"action":"create","title":"Lunch","start":"2026-01-01T12:00:00Z","end":"2026-01-01T13:00:00Z"}"#)
        #expect(out.isError == false)
        #expect(out.outputJSON.contains("awaiting_confirmation"))
        // Exactly one proposal staged; the tool itself never commits.
        #expect(stager.staged.count == 1)
        #expect(stager.staged.first?.op == .create)
        #expect(stager.staged.first?.event.title == "Lunch")
        #expect(await stub.commitCalls == 0)
    }

    @Test func createRequiresTitleAndStart() async throws {
        let (t, _, stager) = tool(access: .fullAccess, writes: true)
        let out = try await t.invoke(arguments: #"{"action":"create"}"#)
        #expect(out.isError == true)
        #expect(stager.staged.isEmpty)
    }

    @Test func editDeleteRequireEventID() async throws {
        let (t, _, stager) = tool(access: .fullAccess, writes: true)
        let edit = try await t.invoke(arguments: #"{"action":"edit","title":"New"}"#)
        #expect(edit.isError == true)
        let del = try await t.invoke(arguments: #"{"action":"delete"}"#)
        #expect(del.isError == true)
        #expect(stager.staged.isEmpty)
    }

    @Test func deleteStagesProposalWithHumanReadableSummary() async throws {
        let (t, _, stager) = tool(access: .fullAccess, writes: true, pool: sample())
        let out = try await t.invoke(arguments: #"{"action":"delete","event_id":"evt-1"}"#)
        #expect(out.isError == false)
        let p = stager.staged.first
        #expect(p?.op == .delete)
        #expect(p?.event.id == "evt-1")
        // The summary shows the event's TITLE, not the raw UUID/id.
        #expect(p?.summary.contains("Standup") == true)
        #expect(p?.summary.contains("evt-1") == false)
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

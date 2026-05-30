// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
@testable import FChatProviders

@Suite("SSEParser")
struct SSEParserTests {
    @Test func basicEventParses() {
        let parser = SSEParser()
        let events = parser.feed("event: foo\ndata: hello\n\n")
        #expect(events.count == 1)
        #expect(events.first?.event == "foo")
        #expect(events.first?.data == "hello")
    }

    @Test func multiLineDataIsJoined() {
        let parser = SSEParser()
        let events = parser.feed("data: line1\ndata: line2\n\n")
        #expect(events.first?.data == "line1\nline2")
    }

    @Test func ignoresCommentsAndUnknownFields() {
        let parser = SSEParser()
        let events = parser.feed(":this is a comment\ndata: x\nretry: 5000\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "x")
    }

    @Test func chunkedInputAcrossNewlinesParsesIntoOneEvent() {
        let parser = SSEParser()
        var events = parser.feed("event: chu")
        #expect(events.isEmpty)
        events = parser.feed("nk\ndata: ")
        #expect(events.isEmpty)
        events = parser.feed("part1\ndata: part2\n\n")
        #expect(events.count == 1)
        #expect(events.first?.event == "chunk")
        #expect(events.first?.data == "part1\npart2")
    }

    @Test func crlfHandled() {
        let parser = SSEParser()
        let events = parser.feed("event: x\r\ndata: y\r\n\r\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "y")
    }

    @Test func leadingSpaceInDataValueStripped() {
        let parser = SSEParser()
        let events = parser.feed("data: hello world\n\n")
        #expect(events.first?.data == "hello world")
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders

/// Proves that the streaming refactor in `ProviderStreaming.runSSEStream` is
/// behavior-preserving: feeding `SSEParser` line-by-line (the new path —
/// `URLSession.AsyncBytes.lines` strips the terminator, we re-append "\n") must
/// produce exactly the same `SSEEvent` sequence as the old byte-buffered path
/// (accumulate raw bytes up to and including each "\n", decode the whole region
/// to a String, feed that).
///
/// We reproduce both feeding strategies here against the same canned bytes,
/// including a CRLF transcript and an arbitrary mid-line chunk split, and
/// assert the decoded events are identical.
@Suite("SSE stream feeding equivalence")
struct SSEStreamEquivalenceTests {
    /// Old path: accumulate bytes into a buffer, and at every "\n" decode the
    /// whole accumulated region to a String and feed it to the parser. This is
    /// the exact logic that `runSSEStream` used before the `.lines` rewrite.
    private func eventsViaByteBuffer(_ data: Data) -> [SSEEvent] {
        let parser = SSEParser()
        var out: [SSEEvent] = []
        var buffer = Data()
        for byte in data {
            buffer.append(byte)
            if byte == UInt8(ascii: "\n") {
                if let chunk = String(data: buffer, encoding: .utf8) {
                    buffer.removeAll(keepingCapacity: true)
                    out.append(contentsOf: parser.feed(chunk))
                }
            }
        }
        out.append(contentsOf: parser.finish())
        return out
    }

    /// New path: split into lines (stripping the terminator, CRLF-aware) and
    /// feed `line + "\n"` to the parser — mirrors `bytes.lines`.
    private func eventsViaLines(_ data: Data) -> [SSEEvent] {
        let text = String(decoding: data, as: UTF8.self)
        // Mimic AsyncBytes.lines: split on \n / \r\n / \r, terminators removed.
        let lines = splitIntoLines(text)
        let parser = SSEParser()
        var out: [SSEEvent] = []
        for line in lines {
            out.append(contentsOf: parser.feed(line + "\n"))
        }
        out.append(contentsOf: parser.finish())
        return out
    }

    /// Line split matching `URLSession.AsyncBytes.lines` semantics: breaks on
    /// LF, CRLF, or lone CR, with terminators stripped. A trailing terminator
    /// does NOT yield a final empty line (matches AsyncSequence line splitting).
    private func splitIntoLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var iterator = text.makeIterator()
        var pendingCR = false
        func flush() { lines.append(current); current = "" }
        while let ch = iterator.next() {
            if pendingCR {
                pendingCR = false
                if ch == "\n" { flush(); continue }   // CRLF
                flush()                                 // lone CR ended a line
            }
            if ch == "\r" { pendingCR = true; continue }
            if ch == "\n" { flush(); continue }
            current.append(ch)
        }
        if pendingCR { flush() }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private func assertEquivalent(_ raw: String, _ comment: Comment) {
        let data = Data(raw.utf8)
        let a = eventsViaByteBuffer(data)
        let b = eventsViaLines(data)
        #expect(a == b, comment)
    }

    @Test func plainLFTranscript() {
        assertEquivalent(
            "event: foo\ndata: hello\n\nevent: bar\ndata: world\n\n",
            "LF-delimited events should decode identically"
        )
    }

    @Test func crlfTranscript() {
        assertEquivalent(
            "event: x\r\ndata: y\r\n\r\ndata: z\r\n\r\n",
            "CRLF terminators should decode identically"
        )
    }

    @Test func multiDataLines() {
        assertEquivalent(
            "data: line1\ndata: line2\n\n",
            "multi-line data should join the same way"
        )
    }

    @Test func commentsAndRetry() {
        assertEquivalent(
            ":keep-alive comment\ndata: a\nretry: 5000\n\n",
            "comments and retry fields handled the same"
        )
    }

    @Test func openAIStyleDoneSentinel() {
        assertEquivalent(
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"i\",\"delta\":\"hi\"}\n\ndata: [DONE]\n\n",
            "OpenAI-style data frames + [DONE] sentinel"
        )
    }

    @Test func anthropicStyleNamedEvents() {
        assertEquivalent(
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
            "Anthropic-style named events"
        )
    }

    @Test func unterminatedFinalLineIsEqualOrBetter() {
        // Edge case: a stream whose final line has NO terminator at all
        // ("…data: last" with no trailing "\n"). This never happens with real
        // SSE (events always end with a blank line), but it's the one input
        // where the two feeding strategies legitimately differ:
        //   - old byte path: the unterminated tail never reached a "\n", so it
        //     was silently dropped — the final data line was LOST.
        //   - new .lines path: the line splitter surfaces the final line, so
        //     the data is preserved.
        // The new behavior is strictly *better* (no data loss) and never worse,
        // which satisfies the "equal-or-better" constraint. Assert the new
        // path recovers the trailing data.
        let data = Data("event: e\ndata: last".utf8)
        let b = eventsViaLines(data)
        #expect(b == [SSEEvent(event: "e", data: "last")])
    }
}

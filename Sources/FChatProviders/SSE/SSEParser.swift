// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Minimal Server-Sent Events line parser. Accepts a stream of bytes and
/// yields complete events as they finish. Compliant enough for the
/// OpenAI Responses streaming format.
public struct SSEEvent: Sendable, Hashable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

public final class SSEParser {
    private var buffer = ""
    private var pendingEvent: String?
    private var pendingID: String?
    private var pendingData: [String] = []

    public init() {}

    /// Feed a chunk of UTF-8 text. Returns any events that completed.
    public func feed(_ chunk: String) -> [SSEEvent] {
        buffer += chunk
        var events: [SSEEvent] = []

        while let newlineRange = buffer.range(of: "\n", options: .literal) {
            var line = String(buffer[..<newlineRange.lowerBound])
            buffer.removeSubrange(..<newlineRange.upperBound)
            if line.hasSuffix("\r") { line.removeLast() }

            if line.isEmpty {
                if let event = flush() {
                    events.append(event)
                }
                continue
            }

            if line.hasPrefix(":") { continue } // comment

            let (field, value) = parseField(line)
            switch field {
            case "event": pendingEvent = value
            case "id": pendingID = value
            case "data": pendingData.append(value)
            case "retry": break // ignored
            default: break
            }
        }

        return events
    }

    public func finish() -> [SSEEvent] {
        if !buffer.isEmpty {
            let leftover = buffer
            buffer = ""
            return feed(leftover + "\n\n")
        }
        return flush().map { [$0] } ?? []
    }

    private func flush() -> SSEEvent? {
        guard !pendingData.isEmpty || pendingEvent != nil else { return nil }
        let data = pendingData.joined(separator: "\n")
        let event = SSEEvent(event: pendingEvent, data: data, id: pendingID)
        pendingEvent = nil
        pendingID = nil
        pendingData.removeAll(keepingCapacity: true)
        return event
    }

    private func parseField(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = String(line[..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (field, value)
    }
}

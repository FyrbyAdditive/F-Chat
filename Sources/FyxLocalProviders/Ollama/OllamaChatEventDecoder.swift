// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// Decodes Ollama native chat NDJSON lines into wire-neutral `StreamEvent`s.
/// Stateful (one instance per stream): accumulates assistant text so the
/// terminal `"done":true` line can emit `textCompleted`, and counts tool
/// calls to mint synthetic call ids (Ollama doesn't assign them).
///
/// Line flow:
///   first line                → .responseStarted (synthetic id)
///   message.thinking          → .reasoningSummaryDelta
///   message.content           → .textDelta (accumulated)
///   message.tool_calls        → .toolCallStarted + .toolCallCompleted per
///                               call (calls arrive complete, not fragmented;
///                               arguments object re-serialized to JSON text)
///   done:true                 → .textCompleted? + .usage + .completed
///   {"error": "..."}          → .responseError
public final class OllamaChatEventDecoder {
    private var startedEmitted = false
    private let itemID = UUID().uuidString
    private var accumulatedText = ""
    private var toolCallCount = 0

    public init() {}

    public func decode(_ line: String) throws -> [StreamEvent] {
        guard let data = line.data(using: .utf8) else { return [] }
        let chunk: Chunk
        do {
            chunk = try JSONDecoder().decode(Chunk.self, from: data)
        } catch {
            // Unknown line — skip rather than fail the stream.
            return []
        }

        var events: [StreamEvent] = []

        if let error = chunk.error {
            events.append(.responseError(message: error, code: nil))
            return events
        }

        if !startedEmitted {
            startedEmitted = true
            events.append(.responseStarted(id: itemID))
        }

        if let thinking = chunk.message?.thinking, !thinking.isEmpty {
            events.append(.reasoningSummaryDelta(itemID: itemID, delta: thinking))
        }

        if let content = chunk.message?.content, !content.isEmpty {
            accumulatedText += content
            events.append(.textDelta(itemID: itemID, delta: content))
        }

        if let calls = chunk.message?.tool_calls {
            for call in calls {
                toolCallCount += 1
                // Ollama omits call ids; mint one. The runner keys pending
                // args by this id and the encoder resolves the tool name from
                // the matching functionCall item, so synthetic ids are fine.
                let callID = "ollama_call_\(toolCallCount)"
                let name = call.function?.name ?? ""
                let argsJSON = Self.serializeArguments(call.function?.arguments)
                events.append(.toolCallStarted(itemID: itemID, callID: callID, name: name))
                events.append(.toolCallCompleted(itemID: itemID, callID: callID, name: name, arguments: argsJSON))
            }
        }

        if chunk.done == true {
            if !accumulatedText.isEmpty {
                events.append(.textCompleted(itemID: itemID, fullText: accumulatedText))
                accumulatedText = ""
            }
            events.append(.usage(UsageInfo(
                inputTokens: chunk.prompt_eval_count ?? 0,
                outputTokens: chunk.eval_count ?? 0
            )))
            events.append(.completed)
        }

        return events
    }

    /// Tool-call arguments arrive as a JSON *object*; the runtime keys
    /// everything off the JSON-string form the other providers use.
    static func serializeArguments(_ value: JSONValue?) -> String {
        guard let value else { return "{}" }
        let obj = value.anyValue
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - Payloads

    private struct Chunk: Decodable {
        let message: Message?
        let done: Bool?
        let error: String?
        let prompt_eval_count: Int?
        let eval_count: Int?
    }

    private struct Message: Decodable {
        let content: String?
        let thinking: String?
        let tool_calls: [ToolCall]?
    }

    private struct ToolCall: Decodable {
        let function: Fn?
        struct Fn: Decodable {
            let name: String?
            let arguments: JSONValue?
        }
    }
}

/// Minimal JSON value tree for decoding tool-call `arguments` (an arbitrary
/// object) via Decodable, then re-serializing through JSONSerialization.
enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    /// Bridge back to Foundation types for JSONSerialization.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            // Keep integers integral so {"x":1} doesn't become {"x":1.0}.
            return n.truncatingRemainder(dividingBy: 1) == 0 && n.magnitude < 1e15 ? Int(n) : n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }
}

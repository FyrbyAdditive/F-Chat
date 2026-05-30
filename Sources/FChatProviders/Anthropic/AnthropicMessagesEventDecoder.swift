// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// Decodes Anthropic Messages API SSE events into wire-neutral `StreamEvent`s.
/// Tolerant of unknown event types (dropped silently).
///
/// Anthropic streams a sequence of content *blocks*, each identified by an
/// integer `index`. A block is one of `text`, `tool_use`, or `thinking`. We
/// keep per-block state (kind, accumulated text/args, tool id+name) so a
/// `content_block_stop` can emit the right completion event, and so partial
/// `input_json_delta`s for a `tool_use` block can be reassembled into the full
/// arguments JSON string the rest of the runtime expects.
///
/// Event flow:
///   message_start            → .responseStarted(id); seed input-token usage
///   content_block_start      → (tool_use) .toolCallStarted
///   content_block_delta      → .textDelta / .toolCallArgumentsDelta / .reasoningSummaryDelta
///   content_block_stop       → .textCompleted / .toolCallCompleted
///   message_delta            → .usage (output tokens; carries stop_reason)
///   message_stop             → .completed
///   error                    → .responseError
public final class AnthropicMessagesEventDecoder {
    private enum BlockKind {
        case text
        case toolUse(callID: String, name: String)
        case thinking
        case other
    }

    private struct BlockState {
        var kind: BlockKind
        var itemID: String
        var text: String = ""
        var argsJSON: String = ""
    }

    private var blocks: [Int: BlockState] = [:]
    private var messageID: String = ""
    private var inputTokens: Int = 0

    public init() {}

    public func decode(_ sse: SSEEvent) throws -> StreamEvent? {
        let typeName = sse.event ?? extractType(from: sse.data) ?? ""
        guard let data = sse.data.data(using: .utf8) else { return nil }

        switch typeName {
        case "message_start":
            let p = try JSONDecoder().decode(MessageStart.self, from: data)
            messageID = p.message.id
            inputTokens = p.message.usage?.input_tokens ?? 0
            return .responseStarted(id: p.message.id)

        case "content_block_start":
            let p = try JSONDecoder().decode(ContentBlockStart.self, from: data)
            let itemID = "\(messageID):\(p.index)"
            switch p.content_block.type {
            case "tool_use":
                let callID = p.content_block.id ?? itemID
                let name = p.content_block.name ?? ""
                blocks[p.index] = BlockState(kind: .toolUse(callID: callID, name: name), itemID: itemID)
                return .toolCallStarted(itemID: itemID, callID: callID, name: name)
            case "thinking":
                blocks[p.index] = BlockState(kind: .thinking, itemID: itemID)
                return nil
            case "text":
                blocks[p.index] = BlockState(kind: .text, itemID: itemID)
                return nil
            default:
                blocks[p.index] = BlockState(kind: .other, itemID: itemID)
                return nil
            }

        case "content_block_delta":
            let p = try JSONDecoder().decode(ContentBlockDelta.self, from: data)
            guard var state = blocks[p.index] else { return nil }
            switch p.delta.type {
            case "text_delta":
                let chunk = p.delta.text ?? ""
                state.text += chunk
                blocks[p.index] = state
                return .textDelta(itemID: state.itemID, delta: chunk)
            case "input_json_delta":
                let chunk = p.delta.partial_json ?? ""
                state.argsJSON += chunk
                blocks[p.index] = state
                if case .toolUse(let callID, _) = state.kind {
                    return .toolCallArgumentsDelta(itemID: state.itemID, callID: callID, delta: chunk)
                }
                return nil
            case "thinking_delta":
                let chunk = p.delta.thinking ?? ""
                return .reasoningSummaryDelta(itemID: state.itemID, delta: chunk)
            default:
                return nil
            }

        case "content_block_stop":
            let p = try JSONDecoder().decode(ContentBlockStop.self, from: data)
            guard let state = blocks[p.index] else { return nil }
            blocks[p.index] = nil
            switch state.kind {
            case .text:
                return .textCompleted(itemID: state.itemID, fullText: state.text)
            case .toolUse(let callID, let name):
                // Anthropic sends "{}" implicitly when a tool takes no input;
                // normalise an empty accumulation to a valid empty object.
                let args = state.argsJSON.isEmpty ? "{}" : state.argsJSON
                return .toolCallCompleted(itemID: state.itemID, callID: callID, name: name, arguments: args)
            case .thinking, .other:
                return nil
            }

        case "message_delta":
            let p = try JSONDecoder().decode(MessageDelta.self, from: data)
            let out = p.usage?.output_tokens ?? 0
            return .usage(UsageInfo(inputTokens: inputTokens, outputTokens: out))

        case "message_stop":
            return .completed

        case "error":
            let p = try JSONDecoder().decode(ErrorEvent.self, from: data)
            return .responseError(message: p.error.message, code: p.error.type)

        case "ping":
            return nil

        default:
            return nil
        }
    }

    private func extractType(from json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(TypeOnly.self, from: data))?.type
    }

    private struct TypeOnly: Decodable { let type: String? }

    // MARK: - Payloads

    private struct MessageStart: Decodable {
        struct M: Decodable {
            let id: String
            let usage: U?
            struct U: Decodable { let input_tokens: Int? }
        }
        let message: M
    }

    private struct ContentBlockStart: Decodable {
        let index: Int
        let content_block: Block
        struct Block: Decodable {
            let type: String
            let id: String?
            let name: String?
        }
    }

    private struct ContentBlockDelta: Decodable {
        let index: Int
        let delta: Delta
        struct Delta: Decodable {
            let type: String
            let text: String?
            let partial_json: String?
            let thinking: String?
        }
    }

    private struct ContentBlockStop: Decodable {
        let index: Int
    }

    private struct MessageDelta: Decodable {
        let usage: U?
        struct U: Decodable { let output_tokens: Int? }
    }

    private struct ErrorEvent: Decodable {
        let error: E
        struct E: Decodable {
            let type: String?
            let message: String
        }
    }
}

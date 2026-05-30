// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Maps a model id to the appropriate tokenizer. Falls back to cl100k_base
/// for unknown models with a reasonable error margin (~±10%) — documented
/// in the token meter UI.
public actor TokenizerRegistry {
    public static let shared = TokenizerRegistry()

    private var cache: [TokenizerID: any Tokenizer] = [:]

    private let mappings: [(prefix: String, tokenizer: TokenizerID)] = [
        // Order matters: more specific prefixes first.
        ("gpt-4o", .o200kBase),
        ("gpt-4.", .o200kBase),
        ("gpt-4-", .o200kBase),
        ("gpt-4", .cl100kBase),
        ("chatgpt-", .o200kBase),
        ("o1", .o200kBase),
        ("o3", .o200kBase),
        ("o4", .o200kBase),
        ("text-embedding-3", .cl100kBase),
        ("text-embedding-ada-002", .cl100kBase),
        ("gpt-3.5", .cl100kBase),
        ("cyankiwi/minimax", .minimax),
        ("minimaxai/minimax", .minimax),
    ]

    public func tokenizer(for modelID: String) -> any Tokenizer {
        let id = resolve(modelID: modelID)
        if let cached = cache[id] { return cached }
        let loaded = load(id)
        cache[id] = loaded
        return loaded
    }

    public func resolve(modelID: String) -> TokenizerID {
        let lower = modelID.lowercased()
        for mapping in mappings where lower.hasPrefix(mapping.prefix) {
            return mapping.tokenizer
        }
        return .cl100kBase
    }

    private func load(_ id: TokenizerID) -> any Tokenizer {
        do {
            switch id {
            case .cl100kBase:
                return try loadTikToken(resource: "cl100k_base", name: "cl100k_base")
            case .o200kBase:
                return try loadTikToken(resource: "o200k_base", name: "o200k_base")
            case .minimax:
                // MiniMax tokenizer.json consumer is a sizeable separate
                // codepath. Until that lands we fall back to cl100k_base
                // (~±10% accuracy). The meter surface explains.
                return try loadTikToken(resource: "cl100k_base", name: "minimax-fallback-cl100k")
            }
        } catch {
            // Last-resort fallback: a heuristic char/token estimator. We
            // should never hit this in production — the resources are
            // bundled. If we do, the budget meter is approximate but
            // non-zero, which is preferable to crashing.
            return HeuristicTokenizer()
        }
    }

    private func loadTikToken(resource: String, name: String) throws -> any Tokenizer {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "tiktoken") else {
            throw TokenizerError.resourceMissing("\(resource).tiktoken")
        }
        let data = try Data(contentsOf: url)
        let encoder = try TikTokenLoader.loadEncoder(from: data)
        return BPETokenizer(name: name, encoder: encoder)
    }
}

public enum TokenizerID: Hashable, Sendable {
    case cl100kBase
    case o200kBase
    case minimax
}

/// Cheap fallback that estimates ~4 chars/token. Only used if the bundled
/// vocab resources are missing or corrupt.
public struct HeuristicTokenizer: Tokenizer {
    public let name = "heuristic-chars-per-token"
    public let vocabularyCount = 0
    public init() {}
    public func encode(_ text: String) -> [Int] {
        Array(repeating: 0, count: countTokens(in: text))
    }
    public func countTokens(in text: String) -> Int {
        max(1, text.count / 4)
    }
}

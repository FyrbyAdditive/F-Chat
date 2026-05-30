// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatProviders

@Suite("OpenAIResponsesProvider decoders")
struct ProviderDecodersTests {
    @Test func decodesModelList() throws {
        let json = #"""
        {"data":[
            {"id":"gpt-4o-mini","owned_by":"openai","context_window":128000,"max_output_tokens":16384},
            {"id":"llama-3-70b"}
        ]}
        """#
        let models = try OpenAIResponsesProvider.decodeModels(json.data(using: .utf8)!)
        #expect(models.count == 2)
        #expect(models[0].id == "gpt-4o-mini")
        #expect(models[0].contextWindow == 128000)
        #expect(models[1].id == "llama-3-70b")
        #expect(models[1].contextWindow == nil)
    }

    @Test func decodesVLLMMaxModelLen() throws {
        // vLLM emits max_model_len rather than context_window. The decoder
        // must pick it up so we don't fall through to the 8k fallback for
        // every self-hosted setup.
        let json = #"""
        {"object":"list","data":[
            {"id":"cyankiwi/MiniMax-M2.7-AWQ-4bit","owned_by":"vllm","max_model_len":196608}
        ]}
        """#
        let models = try OpenAIResponsesProvider.decodeModels(json.data(using: .utf8)!)
        #expect(models.first?.contextWindow == 196608)
    }

    @Test func decodesContextLengthAlias() throws {
        // llama.cpp / ollama style.
        let json = #"""
        {"data":[{"id":"qwen2.5:32b","context_length":32768}]}
        """#
        let models = try OpenAIResponsesProvider.decodeModels(json.data(using: .utf8)!)
        #expect(models.first?.contextWindow == 32768)
    }

    @Test func contextWindowTakesPriorityOverOtherFields() throws {
        // When multiple aliases are present, context_window wins.
        let json = #"""
        {"data":[{"id":"x","context_window":100,"max_model_len":200,"context_length":300}]}
        """#
        let models = try OpenAIResponsesProvider.decodeModels(json.data(using: .utf8)!)
        #expect(models.first?.contextWindow == 100)
    }

    @Test func fallsBackToCatalogForKnownHostedModel() throws {
        // OpenAI's actual /v1/models doesn't include a window field;
        // the catalog should fill that in.
        let json = #"{"data":[{"id":"gpt-4o-mini","owned_by":"openai"}]}"#
        let models = try OpenAIResponsesProvider.decodeModels(json.data(using: .utf8)!)
        #expect(models.first?.contextWindow == 128_000)
    }

    @Test func unknownModelStaysNil() throws {
        // No server hint, no catalog entry → nil (ContextBudget will use 8k fallback).
        let json = #"{"data":[{"id":"someones/exotic-model-v0.1"}]}"#
        let models = try OpenAIResponsesProvider.decodeModels(json.data(using: .utf8)!)
        #expect(models.first?.contextWindow == nil)
    }

    @Test func decodesEmbeddingsAndSortsByIndex() throws {
        let json = #"""
        {"data":[
            {"index":1,"embedding":[3.0,4.0]},
            {"index":0,"embedding":[1.0,2.0]}
        ]}
        """#
        let vectors = try ProviderHTTP.decodeEmbeddings(json.data(using: .utf8)!, expectedCount: 2)
        #expect(vectors == [[1.0, 2.0], [3.0, 4.0]])
    }

    @Test func embeddingsCountMismatchThrows() {
        let json = #"{"data":[{"index":0,"embedding":[1.0]}]}"#
        #expect(throws: ProviderError.malformedResponse("embeddings count mismatch: got 1 expected 3")) {
            _ = try ProviderHTTP.decodeEmbeddings(json.data(using: .utf8)!, expectedCount: 3)
        }
    }
}

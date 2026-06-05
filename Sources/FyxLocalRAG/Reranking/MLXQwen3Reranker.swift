// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import FyxLocalTools
@preconcurrency import MLX
@preconcurrency import MLXLMCommon

/// On-device cross-encoder reranker backed by Qwen3-Reranker-0.6B running on MLX.
///
/// Qwen3-Reranker is a `Qwen3ForCausalLM` fine-tuned so that, given a fixed
/// judgement prompt ending in the assistant turn, the next-token logits for the
/// "yes" / "no" tokens encode relevance. We score each (query, passage) pair by
/// one forward pass, take the final-position logits, and softmax over the yes/no
/// pair. Higher `P(yes)` = more relevant.
///
/// Conforms to the Tools-layer `RAGReranker`. Per its contract, `rerank` never
/// throws — any failure (model issue, decode error) returns the input order so
/// rag_search degrades to the fused ranking rather than erroring.
public struct MLXQwen3Reranker: RAGReranker {
    public static let modelID = "mlx-community/Qwen3-Reranker-0.6B-mxfp8"

    /// The official Qwen3-Reranker judgement framing. The model was trained with
    /// this exact system + the assistant being asked to answer "yes"/"no".
    private static let systemPrefix = """
    <|im_start|>system
    Judge whether the Document meets the requirements based on the Query and the Instruct provided. Note that the answer can only be "yes" or "no".<|im_end|>
    <|im_start|>user
    """
    private static let assistantSuffix = """
    <|im_end|>
    <|im_start|>assistant
    <think>

    </think>

    """
    private static let instruct =
        "Given a web search query, retrieve relevant passages that answer the query"

    /// Cap passage length fed to the model so a huge chunk can't blow the
    /// forward-pass tensor. ~2k chars is plenty for a relevance judgement.
    private static let maxPassageChars = 2048

    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func rerank(query: String, hits: [RAGSearchHit], topK: Int) async -> [RAGSearchHit] {
        guard !hits.isEmpty else { return [] }
        do {
            let scored = try await score(query: query, hits: hits)
            // Sort by descending relevance; stable for equal scores by keeping
            // the original (fused) order via enumerated index tiebreak.
            let ordered = scored
                .enumerated()
                .sorted { a, b in
                    a.element.score != b.element.score
                        ? a.element.score > b.element.score
                        : a.offset < b.offset
                }
                .map(\.element.hit)
            return Array(ordered.prefix(topK))
        } catch {
            // Degrade to input order — never fail the tool because of the reranker.
            FileHandle.standardError.write(Data("[FyxLocal] reranker failed, using fused order: \(error)\n".utf8))
            return Array(hits.prefix(topK))
        }
    }

    /// Run one forward pass per hit and return each with its P(yes) score.
    private func score(query: String, hits: [RAGSearchHit]) async throws -> [(hit: RAGSearchHit, score: Float)] {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            let model = context.model
            guard let yesID = tokenizer.convertTokenToId("yes"),
                  let noID = tokenizer.convertTokenToId("no") else {
                throw RerankError.tokensMissing
            }

            var results: [(RAGSearchHit, Float)] = []
            results.reserveCapacity(hits.count)
            for hit in hits {
                let passage = String(hit.text.prefix(Self.maxPassageChars))
                let prompt = Self.systemPrefix
                    + "<Instruct>: \(Self.instruct)\n<Query>: \(query)\n<Document>: \(passage)"
                    + Self.assistantSuffix
                let tokens = tokenizer.encode(text: prompt, addSpecialTokens: false)
                guard !tokens.isEmpty else { results.append((hit, 0)); continue }

                let input = MLXArray(tokens.map { Int32($0) }, [1, tokens.count])
                let logits = model.callAsFunction(input, cache: nil)   // [1, seqLen, vocab]
                // Final-position logits for the two judgement tokens.
                let last = logits[0, -1, 0...]                          // [vocab]
                let pair = last[MLXArray([Int32(yesID), Int32(noID)])]  // [2]
                let probs = MLX.softmax(pair, axis: -1)
                eval(probs)
                let yesProb = probs[0].item(Float.self)
                results.append((hit, yesProb))
                // Bound Metal buffer growth across the per-hit loop.
                MLX.Memory.clearCache()
            }
            return results
        }
    }

    enum RerankError: Error { case tokensMissing }
}

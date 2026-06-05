// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalTools
import FyxLocalRAG

/// App-layer entry point for obtaining the on-device RAG reranker. Bridges
/// `AppEnvironment` to the MLX-backed `MLXQwen3Reranker` in FyxLocalRAG without
/// AppEnvironment importing MLX directly.
///
/// Loads the bundled Qwen3-Reranker-0.6B container (lazily, once) and wraps it
/// in `MLXQwen3Reranker`. Returns nil on any failure — including FCHAT_SKIP_MLX
/// — so RAG retrieval degrades cleanly to hybrid keyword+vector fusion with no
/// rerank stage.
enum MLXRerankerProvider {
    static func loadShared() async -> (any RAGReranker)? {
        do {
            let container = try await MLXRerankerLoader.shared.shared()
            return MLXQwen3Reranker(container: container)
        } catch {
            FileHandle.standardError.write(Data("[FyxLocal] reranker load failed (using hybrid-only): \(error)\n".utf8))
            return nil
        }
    }
}

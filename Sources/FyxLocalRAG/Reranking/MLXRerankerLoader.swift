// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// Loads the bundled Qwen3-Reranker-0.6B `ModelContainer` from the app's
/// Resources directory. Vendored — no network, no first-run download. Mirrors
/// `MLXEmbedderLoader`: tiny public surface, lazy single load shared by all
/// callers, honours `FCHAT_SKIP_MLX` (returns nil) so the test suite stays
/// MLX-free.
public actor MLXRerankerLoader {
    public static let shared = MLXRerankerLoader()

    /// Bundled model directory name under `Bundle.module`.
    public static let bundledModelName = "Qwen3-Reranker-0.6B-mxfp8"

    public enum LoaderError: Error {
        case bundledModelMissing
        case skippedByEnvironment
    }

    private init() {}

    private var container: ModelContainer?
    private var loadingTask: Task<ModelContainer, Error>?

    /// Returns the shared reranker container, loading from bundled resources on
    /// first call. Concurrent first-callers await the same load. Throws
    /// `skippedByEnvironment` under FCHAT_SKIP_MLX so callers degrade quietly.
    public func shared() async throws -> ModelContainer {
        if ProcessInfo.processInfo.environment["FCHAT_SKIP_MLX"] == "1" {
            throw LoaderError.skippedByEnvironment
        }
        if let container { return container }
        if let loadingTask { return try await loadingTask.value }

        let task = Task<ModelContainer, Error> {
            let directory = try Self.bundledModelDirectory()
            let tokenizerLoader = #huggingFaceTokenizerLoader()
            let container = try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: tokenizerLoader
            )
            return container
        }
        loadingTask = task
        do {
            let result = try await task.value
            container = result
            loadingTask = nil
            return result
        } catch {
            loadingTask = nil
            throw error
        }
    }

    public var isLoaded: Bool { container != nil }
    public func unloadIfIdle() { container = nil }

    /// Resolve the bundled model directory URL (same lookup as the embedder).
    static func bundledModelDirectory() throws -> URL {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: bundledModelName, withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL.appendingPathComponent(bundledModelName, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw LoaderError.bundledModelMissing
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
@preconcurrency import MLXLMCommon
@preconcurrency import MLXEmbedders
import MLXHuggingFace
// Pulled in via the swift-transformers package so the MLXHuggingFace
// tokenizer macro can expand to AutoTokenizer.from(modelFolder:).
import Tokenizers

/// Loads the bundled Qwen3-Embedding-4B `EmbedderModelContainer` from
/// the app's Resources directory. Vendored — no network access required,
/// no download progress, no first-run delay other than JIT-compiling
/// MLX Metal kernels on the first embed call.
///
/// Public surface is intentionally tiny: `shared()` returns the lazily-
/// loaded container; `unloadIfIdle()` is for tests / memory-pressure
/// handlers.
public actor MLXEmbedderLoader {
    public static let shared = MLXEmbedderLoader()

    /// Name of the bundled model directory under `Bundle.module`.
    public static let bundledModelName = "Qwen3-Embedding-4B-4bit-DWQ"

    public enum LoaderError: Error {
        case bundledModelMissing
    }

    private init() {}

    private var container: EmbedderModelContainer?
    private var loadingTask: Task<EmbedderModelContainer, Error>?

    /// Returns the shared model container, loading it from the bundled
    /// resources on first call. Subsequent calls are O(1) after the
    /// first load completes. Concurrent first-callers all await the
    /// same load.
    public func shared() async throws -> EmbedderModelContainer {
        if let container { return container }
        if let loadingTask { return try await loadingTask.value }

        let task = Task<EmbedderModelContainer, Error> {
            let directory = try Self.bundledModelDirectory()
            let tokenizerLoader = #huggingFaceTokenizerLoader()
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: directory,
                using: tokenizerLoader
            )
            // Pre-warm: first call into the model JIT-compiles Metal
            // kernels, which can take 1-3s. Burn it now so the first
            // real ingest call isn't sluggish.
            do {
                let embedder = MLXQwen3Embedder(container: container)
                _ = try await embedder.embed(["warmup"])
            } catch {
                // Pre-warm failures aren't fatal — log and move on; the
                // real first embed call will surface the error.
                FileHandle.standardError.write(Data("[FChat] MLX warmup failed: \(error)\n".utf8))
            }
            return container
        }
        loadingTask = task
        let result: EmbedderModelContainer
        do {
            result = try await task.value
        } catch {
            loadingTask = nil
            throw error
        }
        container = result
        loadingTask = nil
        return result
    }

    /// Drop the cached container so the next `shared()` call reloads.
    /// Used by tests and (future) memory-pressure handlers.
    public func unloadIfIdle() {
        container = nil
    }

    /// `true` after the container has been loaded into memory at least
    /// once this session.
    public var isLoaded: Bool { container != nil }

    /// Resolve the bundled model directory URL. The Swift Package Manager
    /// copies the entire model folder into `Bundle.module` as a single
    /// resource; the directory ends up under either
    /// `Resources/<name>` (regular bundle layout) or as a top-level
    /// child of the module's resource bundle.
    static func bundledModelDirectory() throws -> URL {
        let bundle = Bundle.module
        // Primary lookup: SwiftPM nests under `Contents/Resources/<name>`.
        if let url = bundle.url(forResource: bundledModelName, withExtension: nil),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // Fallback: walk the bundle's resourceURL.
        if let resourceURL = bundle.resourceURL {
            let candidate = resourceURL.appendingPathComponent(bundledModelName, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw LoaderError.bundledModelMissing
    }
}

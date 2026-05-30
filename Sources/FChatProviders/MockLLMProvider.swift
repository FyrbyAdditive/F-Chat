// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// A scriptable mock provider. Use `MockLLMProvider(script: [.text("hello"), .completed])`
/// to feed canned `StreamEvent`s back to a consumer.
public actor MockLLMProvider: LLMProvider {
    nonisolated public let id: ProviderID
    private var nextScript: [[StreamEvent]]
    private var modelList: [ModelInfo]
    private var embeddings: [[Float]]
    public private(set) var receivedRequests: [ChatRequest] = []

    public init(
        id: ProviderID = .init(rawValue: "mock"),
        script: [StreamEvent] = [.completed],
        models: [ModelInfo] = [],
        embeddings: [[Float]] = []
    ) {
        self.id = id
        self.nextScript = [script]
        self.modelList = models
        self.embeddings = embeddings
    }

    public func queueScript(_ events: [StreamEvent]) {
        nextScript.append(events)
    }

    public func listModels() async throws -> [ModelInfo] { modelList }

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        if embeddings.isEmpty {
            // Default: deterministic dummy vectors so callers can still index.
            return texts.map { text in
                Array(repeating: Float(text.count), count: 4)
            }
        }
        return embeddings
    }

    nonisolated public func streamResponse(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let events = await self.popScript(for: request)
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func popScript(for request: ChatRequest) -> [StreamEvent] {
        receivedRequests.append(request)
        if nextScript.count > 1 {
            return nextScript.removeFirst()
        }
        return nextScript.first ?? [.completed]
    }
}

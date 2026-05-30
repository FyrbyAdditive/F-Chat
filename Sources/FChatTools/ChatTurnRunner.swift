// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatProviders

/// Events surfaced from a chat turn — the union of provider stream events plus
/// tool lifecycle events the UI needs to render collapsible tool blocks.
public enum ChatTurnEvent: Sendable, Hashable {
    case responseStarted(id: String)
    case textDelta(itemID: String, delta: String)
    case textCompleted(itemID: String, fullText: String)
    case reasoningSummaryDelta(itemID: String, delta: String)
    case toolCallStarted(callID: String, name: String)
    case toolCallArgumentsDelta(callID: String, delta: String)
    case toolCallReady(callID: String, name: String, arguments: String)
    case toolResult(callID: String, output: ToolOutput)
    case usage(UsageInfo)
    case completed
    case maxIterationsReached
}

public struct ChatTurnRunner: Sendable {
    public let provider: any LLMProvider
    public let registry: ToolRegistry
    public let maxIterations: Int
    public let perToolTimeout: Duration

    public init(
        provider: any LLMProvider,
        registry: ToolRegistry,
        maxIterations: Int = 8,
        perToolTimeout: Duration = .seconds(60)
    ) {
        self.provider = provider
        self.registry = registry
        self.maxIterations = maxIterations
        self.perToolTimeout = perToolTimeout
    }

    public func run(initial: ChatRequest) -> AsyncThrowingStream<ChatTurnEvent, Error> {
        AsyncThrowingStream(ChatTurnEvent.self) { continuation in
            let task = Task {
                do {
                    try await self.drive(initial: initial, emit: { continuation.yield($0) })
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func drive(
        initial: ChatRequest,
        emit: @escaping @Sendable (ChatTurnEvent) -> Void
    ) async throws {
        // Stateless mode: maintain the accumulated input locally across tool
        // iterations rather than relying on `previous_response_id` (which
        // many OpenAI-compatible servers like vLLM do not persist).
        var accumulatedInput = initial.input
        var request = initial
        request.previousResponseID = nil
        request.store = false
        var iteration = 0
        var lastResponseID: String?

        while iteration < maxIterations {
            iteration += 1

            var pendingArgs: [String: String] = [:]
            var toolCallNames: [String: String] = [:]
            var orderedCallIDs: [String] = []

            for try await event in provider.streamResponse(request) {
                try Task.checkCancellation()
                switch event {
                case .responseStarted(let id):
                    lastResponseID = id
                    emit(.responseStarted(id: id))

                case .textDelta(let itemID, let delta):
                    emit(.textDelta(itemID: itemID, delta: delta))
                case .textCompleted(let itemID, let full):
                    emit(.textCompleted(itemID: itemID, fullText: full))
                case .reasoningSummaryDelta(let itemID, let delta):
                    emit(.reasoningSummaryDelta(itemID: itemID, delta: delta))
                case .reasoningEncryptedContent:
                    // Held by the caller via store flag; not surfaced to the UI directly.
                    break

                case .toolCallStarted(_, let callID, let name):
                    if pendingArgs[callID] == nil {
                        pendingArgs[callID] = ""
                        toolCallNames[callID] = name
                        orderedCallIDs.append(callID)
                    }
                    emit(.toolCallStarted(callID: callID, name: name))

                case .toolCallArgumentsDelta(_, let callID, let delta):
                    pendingArgs[callID, default: ""] += delta
                    emit(.toolCallArgumentsDelta(callID: callID, delta: delta))

                case .toolCallCompleted(_, let callID, let name, let arguments):
                    pendingArgs[callID] = arguments
                    if toolCallNames[callID] == nil {
                        toolCallNames[callID] = name
                        orderedCallIDs.append(callID)
                    } else {
                        toolCallNames[callID] = name
                    }
                    emit(.toolCallReady(callID: callID, name: name, arguments: arguments))

                case .usage(let info):
                    emit(.usage(info))

                case .responseError(let message, let code):
                    throw ProviderError.malformedResponse("response error \(code ?? "?"): \(message)")

                case .completed:
                    break
                }
            }

            if orderedCallIDs.isEmpty {
                emit(.completed)
                return
            }

            let invocations = orderedCallIDs.map { callID in
                ToolInvocation(
                    callID: callID,
                    name: toolCallNames[callID] ?? "",
                    arguments: pendingArgs[callID] ?? ""
                )
            }

            let results = await registry.runInvocations(invocations, perToolTimeout: perToolTimeout)
            for (invocation, output) in results {
                emit(.toolResult(callID: invocation.callID, output: output))
            }

            for (invocation, _) in results {
                accumulatedInput.append(.functionCall(
                    callID: invocation.callID,
                    name: invocation.name,
                    argumentsJSON: invocation.arguments
                ))
            }
            for (invocation, output) in results {
                accumulatedInput.append(.functionCallOutput(callID: invocation.callID, outputJSON: output.outputJSON))
            }

            request = ChatRequest(
                model: initial.model,
                input: accumulatedInput,
                instructions: initial.instructions,
                previousResponseID: nil,
                temperature: initial.temperature,
                topP: initial.topP,
                maxOutputTokens: initial.maxOutputTokens,
                reasoningEffort: initial.reasoningEffort,
                parallelToolCalls: initial.parallelToolCalls,
                tools: initial.tools,
                toolChoice: initial.toolChoice,
                store: false,
                includeEncryptedReasoning: initial.includeEncryptedReasoning
            )
            _ = lastResponseID  // kept for diagnostics; not chained
        }

        emit(.maxIterationsReached)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// OpenAI **Chat Completions** API provider (`/chat/completions`, SSE).
///
/// A peer of `OpenAIResponsesProvider`. Many OpenAI-compatible servers
/// (vLLM, Ollama, LM Studio, stepfun) implement Chat Completions most
/// completely — in particular **image input** works here on servers whose
/// `/responses` endpoint is text-only. `/models` and `/embeddings` are the same
/// across both, so those are reused from the Responses provider.
public struct OpenAIChatCompletionsProvider: LLMProvider {
    public let id: ProviderID
    public let baseURL: URL
    public let session: URLSession
    public let secretStore: SecretStore
    public let extraHeaders: [String: String]

    public init(
        id: ProviderID,
        baseURL: URL,
        session: URLSession = .shared,
        secretStore: SecretStore,
        extraHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.baseURL = baseURL
        self.session = session
        self.secretStore = secretStore
        self.extraHeaders = extraHeaders
    }

    public func listModels() async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appending(path: "models"))
        request.httpMethod = "GET"
        try await applyAuth(&request)
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        try ProviderHTTP.validate(response: response, body: data)
        // `/models` is identical to the Responses provider — reuse its decoder.
        return try OpenAIResponsesProvider.decodeModels(data)
    }

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        var request = URLRequest(url: baseURL.appending(path: "embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&request)
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let body: [String: Any] = ["model": model, "input": texts]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await session.data(for: request)
        try ProviderHTTP.validate(response: response, body: data)
        return try ProviderHTTP.decodeEmbeddings(data, expectedCount: texts.count)
    }

    public func streamResponse(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        // Chat Completions ends its stream with a literal `data: [DONE]`.
        streamSSE(
            session: session,
            makeRequest: { try await self.makeStreamRequest(request) },
            makeDecode: {
                let decoder = OpenAIChatCompletionsEventDecoder()
                return { try decoder.decode($0) }
            },
            isDone: { $0.data == "[DONE]" }
        )
    }

    private func makeStreamRequest(_ request: ChatRequest) async throws -> URLRequest {
        var urlReq = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        try await applyAuth(&urlReq)
        for (k, v) in extraHeaders { urlReq.setValue(v, forHTTPHeaderField: k) }
        urlReq.httpBody = try OpenAIChatCompletionsRequestEncoder().encode(request, stream: true)
        return urlReq
    }

    private func applyAuth(_ request: inout URLRequest) async throws {
        if let key = try await secretStore.secret(for: KeychainAccount.providerAPIKey(id)) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

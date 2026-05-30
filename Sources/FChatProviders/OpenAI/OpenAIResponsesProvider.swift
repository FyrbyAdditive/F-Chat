// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

public struct OpenAIResponsesProvider: LLMProvider {
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
        return try Self.decodeModels(data)
    }

    static func decodeModels(_ data: Data) throws -> [ModelInfo] {
        struct ListResponse: Decodable {
            struct Model: Decodable {
                let id: String
                let owned_by: String?
                // Different servers report the context window under different
                // names. Try the lot in priority order.
                let context_window: Int?
                let max_model_len: Int? // vLLM
                let context_length: Int? // llama.cpp, ollama, some others
                let max_context_length: Int?
                let max_output_tokens: Int?
                let max_tokens: Int?
            }
            let data: [Model]
        }
        let parsed = try JSONDecoder().decode(ListResponse.self, from: data)
        return parsed.data.map { m in
            let serverWindow = m.context_window
                ?? m.max_model_len
                ?? m.context_length
                ?? m.max_context_length
            let resolvedWindow = serverWindow ?? KnownModelCatalog.contextWindow(for: m.id)
            let serverMaxOut = m.max_output_tokens ?? m.max_tokens
            return ModelInfo(
                id: m.id,
                displayName: m.id,
                contextWindow: resolvedWindow,
                maxOutputTokens: serverMaxOut
            )
        }
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
        // Provider-specific request + decoder; shared streamer drives the rest.
        // OpenAI ends its stream with a literal `data: [DONE]`.
        streamSSE(
            session: session,
            makeRequest: { try await self.makeStreamRequest(request) },
            makeDecode: {
                let decoder = OpenAIResponsesEventDecoder()
                return { try decoder.decode($0) }
            },
            isDone: { $0.data == "[DONE]" }
        )
    }

    private func makeStreamRequest(_ request: ChatRequest) async throws -> URLRequest {
        var urlReq = URLRequest(url: baseURL.appending(path: "responses"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        try await applyAuth(&urlReq)
        for (k, v) in extraHeaders { urlReq.setValue(v, forHTTPHeaderField: k) }
        urlReq.httpBody = try OpenAIResponsesRequestEncoder().encode(request, stream: true)
        return urlReq
    }

    private func applyAuth(_ request: inout URLRequest) async throws {
        if let key = try await secretStore.secret(for: KeychainAccount.providerAPIKey(id)) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

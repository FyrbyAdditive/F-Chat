// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// `LLMProvider` for the Anthropic Messages API (`/v1/messages`). Mirrors
/// `OpenAIResponsesProvider`'s structure (URLSession.bytes → SSEParser →
/// decoder → continuation) but maps to/from Anthropic's wire format and
/// authenticates with `x-api-key` + `anthropic-version` headers.
///
/// Embeddings have full parity with the OpenAI provider: the method posts to
/// an `/embeddings`-style endpoint for any Anthropic-compatible gateway that
/// offers one. (F-Chat's RAG uses the local MLX embedder regardless of chat
/// provider, so this path is for gateways that expose embeddings.)
public struct AnthropicMessagesProvider: LLMProvider {
    public let id: ProviderID
    public let baseURL: URL
    public let session: URLSession
    public let secretStore: SecretStore
    public let extraHeaders: [String: String]

    /// The Anthropic API version header value. Pinned; bump when adopting
    /// newer wire features.
    public static let anthropicVersion = "2023-06-01"

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
        var models: [ModelInfo] = []
        var afterID: String? = nil
        // Paginate via `has_more` + `last_id`. Bounded to avoid a runaway loop
        // if a gateway misreports has_more.
        for _ in 0..<20 {
            var components = URLComponents(url: baseURL.appending(path: "models"), resolvingAgainstBaseURL: false)
            var queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { queryItems.append(URLQueryItem(name: "after_id", value: afterID)) }
            components?.queryItems = queryItems
            guard let url = components?.url else { break }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            try await applyAuth(&request)
            for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

            let (data, response) = try await session.data(for: request)
            try ProviderHTTP.validate(response: response, body: data)
            let page = try Self.decodeModels(data)
            models.append(contentsOf: page.models)
            guard page.hasMore, let last = page.lastID else { break }
            afterID = last
        }
        return models
    }

    static func decodeModels(_ data: Data) throws -> (models: [ModelInfo], hasMore: Bool, lastID: String?) {
        struct ListResponse: Decodable {
            struct Model: Decodable {
                let id: String
                let display_name: String?
            }
            let data: [Model]
            let has_more: Bool?
            let last_id: String?
        }
        let parsed = try JSONDecoder().decode(ListResponse.self, from: data)
        let models = parsed.data.map { m in
            ModelInfo(
                id: m.id,
                displayName: m.display_name ?? m.id,
                contextWindow: KnownModelCatalog.contextWindow(for: m.id)
            )
        }
        return (models, parsed.has_more ?? false, parsed.last_id)
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
        // Anthropic has no `[DONE]` sentinel — it ends on `message_stop` (mapped
        // to `.completed` by the decoder), so the default `isDone` is used.
        streamSSE(
            session: session,
            makeRequest: { try await self.makeStreamRequest(request) },
            makeDecode: {
                let decoder = AnthropicMessagesEventDecoder()
                return { try decoder.decode($0) }
            }
        )
    }

    private func makeStreamRequest(_ request: ChatRequest) async throws -> URLRequest {
        var urlReq = URLRequest(url: baseURL.appending(path: "messages"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        try await applyAuth(&urlReq)
        for (k, v) in extraHeaders { urlReq.setValue(v, forHTTPHeaderField: k) }
        urlReq.httpBody = try AnthropicMessagesRequestEncoder().encode(request, stream: true)
        return urlReq
    }

    private func applyAuth(_ request: inout URLRequest) async throws {
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if let key = try await secretStore.secret(for: KeychainAccount.providerAPIKey(id)) {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
    }
}

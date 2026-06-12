// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

/// `LLMProvider` for the Ollama native API (`/api/chat`, NDJSON streaming).
///
/// Deliberately the native API rather than Ollama's OpenAI-compat shim:
///  - `/api/tags` + `/api/show` expose per-model `capabilities`
///    (vision/tools/thinking) and the real `context_length`, which the shim's
///    `/v1/models` omits — so context budgeting and the vision gate work from
///    server truth instead of catalog guesses.
///  - chat streams `message.thinking` deltas natively, and the `options`
///    block carries num_ctx/stop/seed/penalties.
///
/// No API key is required; when one IS saved for the provider it's sent as
/// `Authorization: Bearer` to cover proxied/remote Ollama behind auth.
public struct OllamaProvider: LLMProvider {
    public let id: ProviderID
    public let baseURL: URL
    public let session: URLSession
    public let secretStore: SecretStore

    public init(
        id: ProviderID,
        baseURL: URL,
        session: URLSession = .shared,
        secretStore: SecretStore
    ) {
        self.id = id
        self.baseURL = baseURL
        self.session = session
        self.secretStore = secretStore
    }

    // MARK: - Models

    public func listModels() async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
        request.httpMethod = "GET"
        try await applyAuth(&request)
        let (data, response) = try await session.data(for: request)
        try ProviderHTTP.validate(response: response, body: data)
        let names = try Self.decodeTags(data)

        // Enrich each model with /api/show capabilities + context length.
        // One show-call per model is fine: lists are short and the server is
        // typically local. A failed show degrades to a bare entry; it never
        // fails the whole list.
        var models: [ModelInfo] = []
        for name in names {
            if let detail = try? await showModel(name: name) {
                // Embedding-only models can't chat; keep them out of the picker.
                guard detail.capabilities.contains("completion") else { continue }
                models.append(ModelInfo(
                    id: name,
                    displayName: name,
                    contextWindow: detail.contextLength,
                    supportsTools: detail.capabilities.contains("tools"),
                    supportsVision: detail.capabilities.contains("vision"),
                    supportsReasoning: detail.capabilities.contains("thinking")
                ))
            } else {
                models.append(ModelInfo(id: name))
            }
        }
        return models
    }

    struct ModelDetail {
        var capabilities: [String]
        var contextLength: Int?
    }

    private func showModel(name: String) async throws -> ModelDetail {
        var request = URLRequest(url: baseURL.appending(path: "api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name])
        let (data, response) = try await session.data(for: request)
        try ProviderHTTP.validate(response: response, body: data)
        return try Self.decodeShow(data)
    }

    /// `/api/tags` → model names.
    static func decodeTags(_ data: Data) throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]?
        }
        return try JSONDecoder().decode(Tags.self, from: data).models?.map(\.name) ?? []
    }

    /// `/api/show` → capabilities + context length. The context length lives
    /// in `model_info` keyed by model family (e.g. `gemma3.context_length`),
    /// so match on the suffix rather than a fixed key.
    static func decodeShow(_ data: Data) throws -> ModelDetail {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse("api/show: not a JSON object")
        }
        let capabilities = (root["capabilities"] as? [String]) ?? []
        var contextLength: Int?
        if let info = root["model_info"] as? [String: Any] {
            for (key, value) in info where key.hasSuffix(".context_length") {
                if let n = value as? Int { contextLength = n; break }
                if let n = value as? Double { contextLength = Int(n); break }
            }
        }
        return ModelDetail(capabilities: capabilities, contextLength: contextLength)
    }

    // MARK: - Chat

    public func streamResponse(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        streamNDJSON(
            session: session,
            makeRequest: { try await self.makeStreamRequest(request) },
            makeDecode: {
                let decoder = OllamaChatEventDecoder()
                return { try decoder.decode($0) }
            }
        )
    }

    private func makeStreamRequest(_ request: ChatRequest) async throws -> URLRequest {
        var urlReq = URLRequest(url: baseURL.appending(path: "api/chat"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&urlReq)
        urlReq.httpBody = try OllamaChatRequestEncoder().encode(request, stream: true)
        return urlReq
    }

    // MARK: - Embeddings

    public func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        var request = URLRequest(url: baseURL.appending(path: "api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        let (data, response) = try await session.data(for: request)
        try ProviderHTTP.validate(response: response, body: data)
        struct R: Decodable { let embeddings: [[Float]] }
        let parsed = try JSONDecoder().decode(R.self, from: data)
        guard parsed.embeddings.count == texts.count else {
            throw ProviderError.malformedResponse("embeddings count mismatch: got \(parsed.embeddings.count) expected \(texts.count)")
        }
        return parsed.embeddings
    }

    // MARK: - Auth

    private func applyAuth(_ request: inout URLRequest) async throws {
        // Optional: Ollama itself is unauthenticated, but a reverse proxy in
        // front of a remote instance may want a bearer token.
        if let key = try await secretStore.secret(for: KeychainAccount.providerAPIKey(id)), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}

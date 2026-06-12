// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FyxLocalProviders
@testable import FyxLocalCore

// MARK: - Request encoder

@Suite("OllamaChatRequestEncoder")
struct OllamaChatRequestEncoderTests {
    let encoder = OllamaChatRequestEncoder()

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func systemAndBasicMessage() throws {
        let req = ChatRequest(
            model: "gemma3:4b",
            input: [.message(role: .user, content: [.inputText("hi")])],
            instructions: "Be terse."
        )
        let json = try object(try encoder.encode(req, stream: true))
        #expect(json["model"] as? String == "gemma3:4b")
        #expect(json["stream"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "Be terse.")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "hi")
        // No sampling configured → no options object at all.
        #expect(json["options"] == nil)
        #expect(json["think"] == nil)
    }

    @Test func optionsCarrySamplingAndContextWindow() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [.inputText("x")])],
            temperature: 0.7,
            topP: 0.9,
            maxOutputTokens: 512,
            stopSequences: ["END"],
            frequencyPenalty: 0.5,
            presencePenalty: -0.25,
            seed: 42,
            contextWindowHint: 131_072
        )
        let json = try object(try encoder.encode(req, stream: true))
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0.7)
        #expect(options["top_p"] as? Double == 0.9)
        #expect(options["num_predict"] as? Int == 512)
        #expect(options["stop"] as? [String] == ["END"])
        #expect(options["seed"] as? Int == 42)
        #expect(options["frequency_penalty"] as? Double == 0.5)
        #expect(options["presence_penalty"] as? Double == -0.25)
        #expect(options["num_ctx"] as? Int == 131_072)
    }

    @Test func reasoningEffortBecomesThinkFlag() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [.inputText("x")])],
            reasoningEffort: .high
        )
        let json = try object(try encoder.encode(req, stream: true))
        #expect(json["think"] as? Bool == true)
    }

    @Test func imagesRideAsBase64Array() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [
                .inputText("describe"),
                .inputImageData(base64: "QUJD", mimeType: "image/png"),
            ])]
        )
        let json = try object(try encoder.encode(req, stream: true))
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "describe")
        #expect(messages[0]["images"] as? [String] == ["QUJD"])
    }

    @Test func toolRoundTripUsesObjectArgsAndToolName() throws {
        let req = ChatRequest(
            model: "m",
            input: [
                .message(role: .user, content: [.inputText("time?")]),
                .functionCall(callID: "ollama_call_1", name: "get_time", argumentsJSON: #"{"tz":"UTC"}"#),
                .functionCallOutput(callID: "ollama_call_1", outputJSON: #"{"t":"now"}"#),
            ]
        )
        let json = try object(try encoder.encode(req, stream: true))
        let messages = try #require(json["messages"] as? [[String: Any]])
        // user | assistant(tool_calls) | tool
        let assistant = try #require(messages.first { ($0["role"] as? String) == "assistant" })
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        let fn = try #require(calls[0]["function"] as? [String: Any])
        #expect(fn["name"] as? String == "get_time")
        // Arguments are a JSON OBJECT on the Ollama wire, not a string.
        #expect((fn["arguments"] as? [String: Any])?["tz"] as? String == "UTC")
        let tool = try #require(messages.first { ($0["role"] as? String) == "tool" })
        #expect(tool["content"] as? String == #"{"t":"now"}"#)
        // Result keyed by tool name (resolved from the matching call).
        #expect(tool["tool_name"] as? String == "get_time")
    }

    @Test func toolsEncodedOpenAIStyleWithoutToolChoice() throws {
        let req = ChatRequest(
            model: "m",
            input: [.message(role: .user, content: [.inputText("x")])],
            tools: [ToolDefinition(name: "web_search", description: "Search", parametersSchema: .emptyObject)],
            toolChoice: .required
        )
        let json = try object(try encoder.encode(req, stream: true))
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "function")
        #expect((tools[0]["function"] as? [String: Any])?["name"] as? String == "web_search")
        // Ollama has no tool_choice equivalent.
        #expect(json["tool_choice"] == nil)
    }

    @Test func anthropicThinkingContentIsDropped() throws {
        let req = ChatRequest(
            model: "m",
            input: [
                .message(role: .user, content: [.inputText("hi")]),
                .message(role: .assistant, content: [.thinking(text: "secret", signature: "sig")]),
                .message(role: .assistant, content: [.outputText("visible")]),
            ]
        )
        let data = try encoder.encode(req, stream: true)
        let json = try object(data)
        let messages = try #require(json["messages"] as? [[String: Any]])
        // The thinking-only message disappears entirely.
        #expect(messages.count == 2)
        #expect(!String(data: data, encoding: .utf8)!.contains("secret"))
    }
}

// MARK: - Event decoder

@Suite("OllamaChatEventDecoder")
struct OllamaChatEventDecoderTests {
    @Test func textDeltasAccumulateAndCompleteOnDone() throws {
        let d = OllamaChatEventDecoder()
        let first = try d.decode(#"{"model":"m","message":{"role":"assistant","content":"Hel"},"done":false}"#)
        guard case .responseStarted = first.first else { Issue.record("expected started first"); return }
        guard case .textDelta(_, "Hel") = first[1] else { Issue.record("expected textDelta, got \(first)"); return }

        _ = try d.decode(#"{"model":"m","message":{"role":"assistant","content":"lo"},"done":false}"#)
        let done = try d.decode(#"{"model":"m","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":12,"eval_count":34}"#)
        guard case .textCompleted(_, "Hello") = done.first else { Issue.record("expected textCompleted, got \(done)"); return }
        guard case .usage(let info) = done[1] else { Issue.record("expected usage"); return }
        #expect(info.inputTokens == 12)
        #expect(info.outputTokens == 34)
        guard case .completed = done[2] else { Issue.record("expected completed"); return }
    }

    @Test func thinkingDeltasMapToReasoning() throws {
        let d = OllamaChatEventDecoder()
        let ev = try d.decode(#"{"model":"m","message":{"role":"assistant","content":"","thinking":"hmm"},"done":false}"#)
        #expect(ev.contains { if case .reasoningSummaryDelta(_, "hmm") = $0 { return true }; return false })
    }

    @Test func toolCallsGetSyntheticIDsAndSerializedArgs() throws {
        let d = OllamaChatEventDecoder()
        let ev = try d.decode(#"{"model":"m","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_time","arguments":{"tz":"UTC","n":3}}},{"function":{"name":"web_search","arguments":{}}}]},"done":false}"#)
        let started = ev.compactMap { e -> (String, String)? in
            if case .toolCallStarted(_, let id, let name) = e { return (id, name) }; return nil
        }
        let completed = ev.compactMap { e -> (String, String, String)? in
            if case .toolCallCompleted(_, let id, let name, let args) = e { return (id, name, args) }; return nil
        }
        #expect(started.map(\.0) == ["ollama_call_1", "ollama_call_2"])
        #expect(completed.count == 2)
        #expect(completed[0].1 == "get_time")
        // Object arguments round-trip to the JSON-string form, ints intact.
        #expect(completed[0].2.contains(#""tz":"UTC""#))
        #expect(completed[0].2.contains(#""n":3"#))
        #expect(!completed[0].2.contains("3.0"))
        #expect(completed[1].2 == "{}")
    }

    @Test func errorLineBecomesResponseError() throws {
        let d = OllamaChatEventDecoder()
        let ev = try d.decode(#"{"error":"model does not support thinking"}"#)
        guard case .responseError(let message, _) = ev.first else { Issue.record("expected error, got \(ev)"); return }
        #expect(message == "model does not support thinking")
    }
}

// MARK: - Model listing (stubbed /api/tags + /api/show)

@Suite("OllamaProvider model listing")
struct OllamaModelListingTests {
    @Test func decodeTagsAndShow() throws {
        let tags = #"{"models":[{"name":"gemma3:4b","model":"gemma3:4b"},{"name":"nomic-embed-text"}]}"#
        #expect(try OllamaProvider.decodeTags(Data(tags.utf8)) == ["gemma3:4b", "nomic-embed-text"])

        let show = #"{"capabilities":["completion","vision"],"model_info":{"general.architecture":"gemma3","gemma3.context_length":131072,"gemma3.embedding_length":2560}}"#
        let detail = try OllamaProvider.decodeShow(Data(show.utf8))
        #expect(detail.capabilities == ["completion", "vision"])
        #expect(detail.contextLength == 131_072)
    }

    @Test func listModelsEnrichesAndFiltersEmbeddingOnly() async throws {
        let host = OllamaStub.uniqueHost()
        OllamaStub.set(host: host, path: "/api/tags", status: 200, body:
            #"{"models":[{"name":"gemma3:4b"},{"name":"nomic-embed-text"}]}"#)
        // POST /api/show is path-keyed; the stub returns by request body match.
        OllamaStub.setShow(host: host, model: "gemma3:4b", body:
            #"{"capabilities":["completion","vision","thinking"],"model_info":{"gemma3.context_length":131072}}"#)
        OllamaStub.setShow(host: host, model: "nomic-embed-text", body:
            #"{"capabilities":["embedding"],"model_info":{}}"#)

        let provider = OllamaProvider(
            id: ProviderID(rawValue: "ollama-test"),
            baseURL: URL(string: "http://\(host)")!,
            session: OllamaStub.session(),
            secretStore: InMemorySecretStore()
        )
        let models = try await provider.listModels()
        // The embedding-only model is filtered out of the chat picker.
        #expect(models.map(\.id) == ["gemma3:4b"])
        #expect(models[0].contextWindow == 131_072)
        #expect(models[0].supportsVision)
        #expect(models[0].supportsReasoning)
        #expect(!models[0].supportsTools)
    }

    @Test func showFailureDegradesToBareEntry() async throws {
        let host = OllamaStub.uniqueHost()
        OllamaStub.set(host: host, path: "/api/tags", status: 200, body: #"{"models":[{"name":"mystery:latest"}]}"#)
        // No /api/show stub registered → the request 404s via the stub default.
        OllamaStub.set(host: host, path: "/api/show", status: 500, body: "boom")

        let provider = OllamaProvider(
            id: ProviderID(rawValue: "ollama-test2"),
            baseURL: URL(string: "http://\(host)")!,
            session: OllamaStub.session(),
            secretStore: InMemorySecretStore()
        )
        let models = try await provider.listModels()
        #expect(models.map(\.id) == ["mystery:latest"])
        #expect(models[0].contextWindow == nil)
    }
}

// MARK: - Tool-capability resolution (send-path gating)

@Suite("ProviderRecord.supportsTools")
struct SupportsToolsTests {
    private let record = ProviderRecord(
        id: .init(rawValue: "ollama"),
        displayName: "Ollama",
        baseURL: URL(string: "http://localhost:11434")!,
        apiKind: .ollama
    )

    @Test func detectedCapabilityWins() {
        let detected = [
            ModelInfo(id: "gemma3:4b", supportsTools: false),
            ModelInfo(id: "glm4:latest", supportsTools: true),
        ]
        #expect(!record.supportsTools(modelID: "gemma3:4b", detected: detected))
        #expect(record.supportsTools(modelID: "glm4:latest", detected: detected))
    }

    @Test func unknownModelAssumedCapable() {
        // Hosted APIs all support tools; only authoritative capability data
        // (Ollama /api/show) ever reports false.
        #expect(record.supportsTools(modelID: "mystery", detected: []))
    }

    @Test func userOverrideBeatsDetected() {
        var rec = record
        rec.modelOverrides = [ModelOverride(modelID: "gemma3:4b", supportsTools: true)]
        let detected = [ModelInfo(id: "gemma3:4b", supportsTools: false)]
        #expect(rec.supportsTools(modelID: "gemma3:4b", detected: detected))
    }
}

// MARK: - URLProtocol stub (host+path keyed; /api/show keyed by body model)

private final class OllamaStub: URLProtocol, @unchecked Sendable {
    struct Canned { let status: Int; let body: String }

    nonisolated(unsafe) private static var responses: [String: Canned] = [:]
    nonisolated(unsafe) private static var showBodies: [String: String] = [:]  // "host|model" → body
    private static let lock = NSLock()

    static func uniqueHost() -> String { "ollama-\(UUID().uuidString.lowercased()).stub.test" }

    static func set(host: String, path: String, status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        responses["\(host)|\(path)"] = Canned(status: status, body: body)
    }

    static func setShow(host: String, model: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        showBodies["\(host)|\(model)"] = body
        // Ensure canInit matches /api/show for this host.
        responses["\(host)|/api/show"] = Canned(status: 200, body: "{}")
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaStub.self]
        return URLSession(configuration: config)
    }

    private static func canned(for url: URL?) -> Canned? {
        guard let url, let host = url.host else { return nil }
        lock.lock(); defer { lock.unlock() }
        return responses["\(host)|\(url.path)"]
    }

    override class func canInit(with request: URLRequest) -> Bool { canned(for: request.url) != nil }
    override class func canInit(with task: URLSessionTask) -> Bool { canned(for: task.currentRequest?.url) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, var canned = Self.canned(for: url) else {
            client?.urlProtocolDidFinishLoading(self); return
        }
        // /api/show: pick the per-model body from the POSTed {"model": ...}.
        if url.path == "/api/show",
           let bodyData = request.httpBody ?? request.bodyStreamData,
           let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let model = obj["model"] as? String {
            Self.lock.lock()
            let custom = Self.showBodies["\(host)|\(model)"]
            Self.lock.unlock()
            if let custom { canned = Canned(status: 200, body: custom) }
        }
        let resp = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(canned.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLSession moves httpBody into a stream by the time URLProtocol sees
    /// the request; drain it for body inspection in stubs.
    var bodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

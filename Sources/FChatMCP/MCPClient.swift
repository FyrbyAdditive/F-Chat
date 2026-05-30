// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public struct MCPServerInfo: Sendable, Hashable {
    public var name: String
    public var version: String
    public var protocolVersion: String
    public init(name: String, version: String, protocolVersion: String) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
    }
}

public struct MCPTool: Sendable, Hashable {
    public var name: String
    public var description: String
    /// Raw JSON schema (object form).
    public var inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPToolCallResult: Sendable, Hashable {
    public var content: [MCPContent]
    public var isError: Bool
    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}

public enum MCPContent: Sendable, Hashable {
    case text(String)
    case image(base64: String, mimeType: String)
    case resource(uri: String, text: String?)
}

public enum MCPClientError: Error, Sendable, Equatable {
    case notInitialized
    case rpcError(code: Int, message: String)
    case unexpectedResult
    case transportClosed
}

public actor MCPClient {
    public let clientName: String
    public let clientVersion: String
    public let protocolVersion: String

    private let transport: any MCPTransport
    private var nextID: Int = 0
    private var pending: [JSONRPCID: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var notificationContinuation: AsyncStream<JSONRPCNotification>.Continuation?
    private var notificationStream: AsyncStream<JSONRPCNotification>?
    public private(set) var serverInfo: MCPServerInfo?

    public init(
        transport: any MCPTransport,
        clientName: String = "F-Chat",
        clientVersion: String = "0.4.0",
        protocolVersion: String = "2025-11-25"
    ) {
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.protocolVersion = protocolVersion

        let (stream, continuation) = AsyncStream<JSONRPCNotification>.makeStream()
        self.notificationStream = stream
        self.notificationContinuation = continuation
    }

    public func start() async throws {
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
        try await initializeHandshake()
    }

    public func shutdown() async {
        receiveTask?.cancel()
        receiveTask = nil
        await transport.close()
        notificationContinuation?.finish()
        for (_, cont) in pending { cont.resume(throwing: MCPClientError.transportClosed) }
        pending.removeAll()
    }

    public func notifications() -> AsyncStream<JSONRPCNotification> {
        notificationStream ?? AsyncStream { _ in }
    }

    public func listTools() async throws -> [MCPTool] {
        let response = try await call(method: "tools/list", params: nil)
        guard case .success(let value) = response.result else {
            if case .failure(let e) = response.result { throw MCPClientError.rpcError(code: e.code, message: e.message) }
            throw MCPClientError.unexpectedResult
        }
        guard let tools = value["tools"]?.arrayValue else { throw MCPClientError.unexpectedResult }
        var output: [MCPTool] = []
        for tool in tools {
            guard let name = tool["name"]?.stringValue else { continue }
            let description = tool["description"]?.stringValue ?? ""
            let schema = tool["inputSchema"] ?? .object([:])
            output.append(MCPTool(name: name, description: description, inputSchema: schema))
        }
        return output
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> MCPToolCallResult {
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments,
        ])
        let response = try await call(method: "tools/call", params: params)
        switch response.result {
        case .success(let value):
            let contentArray = value["content"]?.arrayValue ?? []
            let isError = value["isError"].flatMap { if case .bool(let b) = $0 { return b } else { return nil } } ?? false
            let content = contentArray.compactMap { decodeContent($0) }
            return MCPToolCallResult(content: content, isError: isError)
        case .failure(let e):
            throw MCPClientError.rpcError(code: e.code, message: e.message)
        }
    }

    private func decodeContent(_ value: JSONValue) -> MCPContent? {
        guard let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "text":
            return value["text"]?.stringValue.map { .text($0) }
        case "image":
            if let b64 = value["data"]?.stringValue, let mt = value["mimeType"]?.stringValue {
                return .image(base64: b64, mimeType: mt)
            }
        case "resource":
            if let res = value["resource"], let uri = res["uri"]?.stringValue {
                return .resource(uri: uri, text: res["text"]?.stringValue)
            }
        default: break
        }
        return nil
    }

    private func initializeHandshake() async throws {
        let params: JSONValue = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ])
        let response = try await call(method: "initialize", params: params)
        guard case .success(let value) = response.result else {
            if case .failure(let e) = response.result {
                throw MCPClientError.rpcError(code: e.code, message: e.message)
            }
            throw MCPClientError.unexpectedResult
        }
        let info = value["serverInfo"]
        let name = info?["name"]?.stringValue ?? "unknown"
        let version = info?["version"]?.stringValue ?? "?"
        let proto = value["protocolVersion"]?.stringValue ?? protocolVersion
        self.serverInfo = MCPServerInfo(name: name, version: version, protocolVersion: proto)

        try await transport.send(.notification(.init(method: "notifications/initialized")))
    }

    private func call(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        nextID += 1
        let id = JSONRPCID.int(nextID)
        let frame = JSONRPCFrame.request(.init(id: id, method: method, params: params))
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do { try await transport.send(frame) }
                catch {
                    if let removed = pending.removeValue(forKey: id) {
                        removed.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func runReceiveLoop() async {
        do {
            for try await frame in transport.incoming() {
                switch frame {
                case .response(let response):
                    if let cont = pending.removeValue(forKey: response.id) {
                        cont.resume(returning: response)
                    }
                case .notification(let n):
                    notificationContinuation?.yield(n)
                case .request:
                    break
                }
            }
        } catch {
            for (_, cont) in pending { cont.resume(throwing: error) }
            pending.removeAll()
        }
        notificationContinuation?.finish()
    }
}

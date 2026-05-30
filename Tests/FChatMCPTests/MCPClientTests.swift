// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatMCP

@Suite("MCPClient", .serialized)
struct MCPClientTests {
    @Test func initializeHandshakeAndListTools() async throws {
        let (clientTransport, serverTransport) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: serverTransport, tools: [
            MCPTool(name: "echo", description: "echoes input", inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["msg": .object(["type": .string("string")])]),
                "required": .array([.string("msg")]),
            ]))
        ])
        await server.start()

        let client = MCPClient(transport: clientTransport, clientName: "test-client", clientVersion: "0.0.1", protocolVersion: "2025-11-25")
        try await client.start()

        let info = await client.serverInfo
        #expect(info?.name == "mock-server")
        #expect(info?.protocolVersion == "2025-11-25")

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["echo"])
        #expect(tools.first?.description == "echoes input")

        let result = try await client.callTool(name: "echo", arguments: .object(["msg": .string("hello")]))
        #expect(result.isError == false)
        guard case .text(let echoed) = result.content.first else { Issue.record("expected text content"); return }
        #expect(echoed == "echo: hello")

        await client.shutdown()
        await server.shutdown()
    }

    @Test func toolCallErrorPropagates() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: [])
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        do {
            _ = try await client.callTool(name: "missing", arguments: .object([:]))
            Issue.record("expected throw")
        } catch let MCPClientError.rpcError(code, message) {
            #expect(code == -32601)
            #expect(message.contains("missing"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        await client.shutdown()
        await server.shutdown()
    }
}

/// Minimal in-process MCP server that knows just enough of the spec to drive
/// `MCPClient` end-to-end through the in-memory transport pair.
actor MockMCPServer {
    private let transport: any MCPTransport
    private let tools: [MCPTool]
    private var task: Task<Void, Never>?

    init(transport: any MCPTransport, tools: [MCPTool]) {
        self.transport = transport
        self.tools = tools
    }

    func start() {
        task = Task { await self.run() }
    }

    func shutdown() async {
        task?.cancel()
        await transport.close()
    }

    private func run() async {
        do {
            for try await frame in transport.incoming() {
                guard case .request(let req) = frame else { continue }
                let response = try await handle(req)
                try? await transport.send(.response(response))
            }
        } catch {
            // transport closed; exit
        }
    }

    private func handle(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        switch req.method {
        case "initialize":
            let value: JSONValue = .object([
                "protocolVersion": .string("2025-11-25"),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string("mock-server"),
                    "version": .string("1.0.0"),
                ]),
            ])
            return JSONRPCResponse(id: req.id, result: .success(value))

        case "tools/list":
            let entries: [JSONValue] = tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                ])
            }
            return JSONRPCResponse(id: req.id, result: .success(.object(["tools": .array(entries)])))

        case "tools/call":
            let name = req.params?["name"]?.stringValue ?? ""
            let args = req.params?["arguments"] ?? .object([:])
            guard tools.contains(where: { $0.name == name }) else {
                return JSONRPCResponse(id: req.id, result: .failure(.init(code: -32601, message: "tool missing: \(name)")))
            }
            let echoed = args["msg"]?.stringValue ?? ""
            let value: JSONValue = .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string("echo: \(echoed)")])
                ]),
                "isError": .bool(false),
            ])
            return JSONRPCResponse(id: req.id, result: .success(value))

        default:
            return JSONRPCResponse(id: req.id, result: .failure(.methodNotFound))
        }
    }
}

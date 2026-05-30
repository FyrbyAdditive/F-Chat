// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatTools
@testable import FChatMCP

@Suite("MCPToolAdapter")
struct MCPToolAdapterTests {
    @Test func namespacedNameAndDefinitionForward() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: [
            MCPTool(name: "search", description: "search the docs", inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["q": .object(["type": .string("string")])]),
                "required": .array([.string("q")]),
            ]))
        ])
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        let tools = try await client.listTools()
        let adapter = MCPToolAdapter(serverName: "docs", mcpTool: tools[0], client: client)
        #expect(adapter.name == "mcp__docs__search")
        let def = adapter.definition(for: .english)
        #expect(def.description == "search the docs")
        #expect(def.parametersSchema.raw.contains(#""type":"object""#))

        await client.shutdown()
        await server.shutdown()
    }

    @Test func invokeForwardsArgumentsAndDeliversText() async throws {
        let (ct, st) = await makeInMemoryTransportPair()
        let server = MockMCPServer(transport: st, tools: [
            MCPTool(name: "echo", description: "x", inputSchema: .object([:]))
        ])
        await server.start()
        let client = MCPClient(transport: ct)
        try await client.start()

        let tools = try await client.listTools()
        let adapter = MCPToolAdapter(serverName: "srv", mcpTool: tools[0], client: client)
        let output = try await adapter.invoke(arguments: #"{"msg":"world"}"#)
        #expect(output.isError == false)
        #expect(output.outputJSON.contains("echo: world"))

        await client.shutdown()
        await server.shutdown()
    }
}

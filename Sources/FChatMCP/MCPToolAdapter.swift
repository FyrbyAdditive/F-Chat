// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatProviders
import FChatTools

/// Wraps a single MCP-discovered tool so it can be registered in our
/// shared `ToolRegistry` alongside built-in tools. The exposed name is
/// namespaced as `mcp__<server>__<tool>` to avoid collisions.
public struct MCPToolAdapter: Tool {
    public let name: String
    public let serverName: String
    public let mcpTool: MCPTool
    private let client: MCPClient

    public init(serverName: String, mcpTool: MCPTool, client: MCPClient) {
        self.serverName = serverName
        self.mcpTool = mcpTool
        self.name = "mcp__\(serverName)__\(mcpTool.name)"
        self.client = client
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let raw = (try? JSONSerialization.data(withJSONObject: mcpTool.inputSchema.toAny(), options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolDefinition(
            name: name,
            description: mcpTool.description,
            parametersSchema: JSONSchema(raw: raw)
        )
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        let args = parseArguments(arguments)
        let result = try await client.callTool(name: mcpTool.name, arguments: args)
        let outputJSON = serializeResult(result)
        let display = inferDisplay(from: result)
        return ToolOutput(outputJSON: outputJSON, isError: result.isError, display: display)
    }

    private func parseArguments(_ arguments: String) -> JSONValue {
        guard let data = arguments.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let value = try? JSONValue(any: any) else {
            return .object([:])
        }
        return value
    }

    private func serializeResult(_ result: MCPToolCallResult) -> String {
        var contentArray: [Any] = []
        for content in result.content {
            switch content {
            case .text(let s):
                contentArray.append(["type": "text", "text": s])
            case .image(let b64, let mt):
                contentArray.append(["type": "image", "data": b64, "mimeType": mt])
            case .resource(let uri, let text):
                var entry: [String: Any] = ["type": "resource", "uri": uri]
                if let text { entry["text"] = text }
                contentArray.append(entry)
            }
        }
        let payload: [String: Any] = [
            "content": contentArray,
            "isError": result.isError,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func inferDisplay(from result: MCPToolCallResult) -> ToolDisplayHint? {
        for content in result.content {
            if case .image = content { return .image }
        }
        return .markdown
    }
}

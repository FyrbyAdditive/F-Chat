// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatProviders

/// Holds the set of tools available for a chat turn. Combines built-in
/// (client-side) tools with MCP-discovered tools, namespaced to avoid
/// collisions.
public actor ToolRegistry {
    private var tools: [String: any Tool] = [:]

    public init() {}

    public func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    public func unregister(name: String) {
        tools[name] = nil
    }

    public func tool(named name: String) -> (any Tool)? {
        tools[name]
    }

    public func allNames() -> [String] {
        Array(tools.keys).sorted()
    }

    public func definitions(for language: PromptLanguage) -> [ToolDefinition] {
        tools.values
            .map { $0.definition(for: language) }
            .sorted { $0.name < $1.name }
    }

    /// Runs all invocations in parallel, returning their outputs in the same
    /// order they were submitted.
    public func runInvocations(
        _ invocations: [ToolInvocation],
        perToolTimeout: Duration = .seconds(60)
    ) async -> [(ToolInvocation, ToolOutput)] {
        await withTaskGroup(of: (Int, ToolInvocation, ToolOutput).self) { group in
            for (index, invocation) in invocations.enumerated() {
                let tool = self.tools[invocation.name]
                group.addTask {
                    let output: ToolOutput
                    if let tool {
                        output = await Self.runOne(tool: tool, invocation: invocation, timeout: perToolTimeout)
                    } else {
                        let payload = #"{"error":"unknown tool '\#(invocation.name)'"}"#
                        output = ToolOutput(outputJSON: payload, isError: true)
                    }
                    return (index, invocation, output)
                }
            }
            var collected: [(Int, ToolInvocation, ToolOutput)] = []
            for await result in group { collected.append(result) }
            return collected
                .sorted { $0.0 < $1.0 }
                .map { ($0.1, $0.2) }
        }
    }

    private static func runOne(
        tool: any Tool,
        invocation: ToolInvocation,
        timeout: Duration
    ) async -> ToolOutput {
        do {
            return try await withThrowingTaskGroup(of: ToolOutput.self) { group in
                group.addTask { try await tool.invoke(arguments: invocation.arguments) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ToolInvocationError.timedOut
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch let error as ToolInvocationError {
            let payload = #"{"error":"\#(escape(String(describing: error)))"}"#
            return ToolOutput(outputJSON: payload, isError: true)
        } catch {
            let payload = #"{"error":"\#(escape(error.localizedDescription))"}"#
            return ToolOutput(outputJSON: payload, isError: true)
        }
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

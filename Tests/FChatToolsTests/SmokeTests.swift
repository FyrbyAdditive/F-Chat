// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatProviders
@testable import FChatTools

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test func registerAndListsAlphabetical() async {
        let r = ToolRegistry()
        await r.register(EchoTool(name: "b_tool"))
        await r.register(EchoTool(name: "a_tool"))
        let names = await r.allNames()
        #expect(names == ["a_tool", "b_tool"])
        let defs = await r.definitions(for: .english)
        #expect(defs.map(\.name) == ["a_tool", "b_tool"])
    }

    @Test func unknownToolYieldsErrorOutput() async {
        let r = ToolRegistry()
        let results = await r.runInvocations([ToolInvocation(callID: "1", name: "missing", arguments: "{}")])
        #expect(results.count == 1)
        #expect(results[0].1.isError == true)
        #expect(results[0].1.outputJSON.contains("unknown tool"))
    }

    @Test func resultsPreserveSubmissionOrder() async {
        let r = ToolRegistry()
        await r.register(EchoTool(name: "fast"))
        await r.register(SlowEchoTool(name: "slow", milliseconds: 50))
        let invocations = [
            ToolInvocation(callID: "a", name: "slow", arguments: #"{"v":"A"}"#),
            ToolInvocation(callID: "b", name: "fast", arguments: #"{"v":"B"}"#),
            ToolInvocation(callID: "c", name: "slow", arguments: #"{"v":"C"}"#),
        ]
        let results = await r.runInvocations(invocations, perToolTimeout: .seconds(5))
        #expect(results.map { $0.0.callID } == ["a", "b", "c"])
    }

    @Test func toolTimeoutSurfaces() async {
        let r = ToolRegistry()
        await r.register(SlowEchoTool(name: "slow", milliseconds: 500))
        let results = await r.runInvocations(
            [ToolInvocation(callID: "x", name: "slow", arguments: "{}")],
            perToolTimeout: .milliseconds(50)
        )
        #expect(results.first?.1.isError == true)
        #expect(results.first?.1.outputJSON.contains("timedOut") == true)
    }
}

struct EchoTool: Tool {
    let name: String
    func definition(for language: PromptLanguage) -> ToolDefinition {
        ToolDefinition(name: name, description: "echo", parametersSchema: .emptyObject)
    }
    func invoke(arguments: String) async throws -> ToolOutput {
        ToolOutput(outputJSON: arguments, display: .json)
    }
}

struct SlowEchoTool: Tool {
    let name: String
    let milliseconds: Int
    func definition(for language: PromptLanguage) -> ToolDefinition {
        ToolDefinition(name: name, description: "slow echo", parametersSchema: .emptyObject)
    }
    func invoke(arguments: String) async throws -> ToolOutput {
        try await Task.sleep(for: .milliseconds(milliseconds))
        return ToolOutput(outputJSON: arguments)
    }
}

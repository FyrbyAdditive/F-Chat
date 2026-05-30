// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
@testable import FChatTools

@Suite("RunCodeTool", .serialized)
struct RunCodeToolTests {
    private func makeSkillDir(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-runcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "marker-\(name)".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func unknownSkillIsError() async throws {
        let tool = RunCodeTool(skills: [])
        let out = try await tool.invoke(arguments: #"{"skill":"nope","language":"bash","code":"echo hi"}"#)
        #expect(out.isError)
        #expect(out.outputJSON.contains("Unknown"))
    }

    @Test func runsBashInNamedSkill() async throws {
        let dir = try makeSkillDir(name: "demo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = RunCodeTool(skills: [.init(name: "demo", directory: dir)])
        guard CodeSandbox().isAvailable(.bash) else { return }
        let out = try await tool.invoke(arguments: #"{"skill":"demo","language":"bash","code":"cat SKILL.md"}"#)
        #expect(!out.isError)
        #expect(out.outputJSON.contains("marker-demo"))
        #expect(out.outputJSON.contains("exit_code"))
    }

    @Test func rejectsBadLanguage() async throws {
        let dir = try makeSkillDir(name: "demo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = RunCodeTool(skills: [.init(name: "demo", directory: dir)])
        let out = try await tool.invoke(arguments: #"{"skill":"demo","language":"ruby","code":"x"}"#)
        #expect(out.isError)
    }

    @Test func rejectsMalformedArguments() async throws {
        let tool = RunCodeTool(skills: [])
        let out = try await tool.invoke(arguments: "not json")
        #expect(out.isError)
    }

    @Test func definitionListsSkillNames() {
        let dir = FileManager.default.temporaryDirectory
        let tool = RunCodeTool(skills: [.init(name: "alpha", directory: dir), .init(name: "beta", directory: dir)])
        let def = tool.definition(for: .english)
        #expect(def.name == "run_code")
        #expect(def.description.contains("alpha"))
        #expect(def.description.contains("beta"))
    }
}

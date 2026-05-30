// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatProviders

/// The `run_code` tool: executes code in a confined sandbox, scoped to the
/// skills enabled for the current chat. This is how Agent Skills reach
/// progressive-disclosure level 3 — the model reads a skill's `SKILL.md`
/// (`cat SKILL.md`) and runs its bundled scripts, with cwd set to the skill's
/// unpacked directory.
///
/// The tool is **skill-scoped**, not a general shell: the model must name a
/// skill it has enabled, and the sandbox confines execution to that skill's
/// directory (read) + its `work/` scratch (write), with no network. A chat
/// with no enabled skills never sees this tool (it isn't registered).
public struct RunCodeTool: Tool {
    public let name = "run_code"

    /// A skill the model may target, with the on-disk root the sandbox runs in.
    public struct EnabledSkill: Sendable, Hashable {
        public let name: String
        public let directory: URL
        public init(name: String, directory: URL) {
            self.name = name
            self.directory = directory
        }
    }

    /// Resolves the skills enabled for the current turn. A single shared
    /// `RunCodeTool` is registered once; the accessor reads per-turn context
    /// (a TaskLocal set by the chat view model) so concurrent chats never see
    /// each other's skills. When constructed with a static list instead, the
    /// accessor just returns it (used in tests).
    private let accessor: @Sendable () -> [EnabledSkill]
    private let sandbox: CodeSandbox

    /// Dynamic form: skills resolved per-invocation via `accessor`.
    public init(sandbox: CodeSandbox = CodeSandbox(), accessor: @escaping @Sendable () -> [EnabledSkill]) {
        self.accessor = accessor
        self.sandbox = sandbox
    }

    /// Static form: a fixed set of skills (tests / one-off use).
    public init(skills: [EnabledSkill], sandbox: CodeSandbox = CodeSandbox()) {
        self.accessor = { skills }
        self.sandbox = sandbox
    }

    private func resolved() -> (map: [String: URL], names: [String]) {
        let list = accessor()
        var map: [String: URL] = [:]
        for s in list { map[s.name] = s.directory }
        return (map, list.map(\.name).sorted())
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let pythonNote = sandbox.isAvailable(.python)
            ? ""
            : (language == .swedish
                ? " (python är inte tillgängligt i den här miljön — använd bash.)"
                : " (python is not available in this environment — use bash.)")
        let skillNames = resolved().names
        let skillList = skillNames.isEmpty ? "—" : skillNames.joined(separator: ", ")
        let description: String
        switch language {
        case .english:
            description = """
            Run code inside a sandboxed environment scoped to one of your \
            enabled skills, to read its files and run its bundled scripts. \
            Set `skill` to the skill name (one of: \(skillList)); the working \
            directory is that skill's folder, so you can `cat SKILL.md`, list \
            files, and run bundled helpers (e.g. `python scripts/foo.py`). \
            Set `language` to "bash" or "python"\(pythonNote). The sandbox has \
            no network access and can only write to its own scratch space. \
            Returns stdout, stderr and the exit code.
            """
        case .swedish:
            description = """
            Kör kod i en sandlåda kopplad till en av dina aktiverade \
            färdigheter ("skills"), för att läsa dess filer och köra medföljande \
            skript. Sätt `skill` till färdighetens namn (en av: \(skillList)); \
            arbetskatalogen är färdighetens mapp, så du kan `cat SKILL.md`, \
            lista filer och köra medföljande skript (t.ex. \
            `python scripts/foo.py`). Sätt `language` till "bash" eller \
            "python"\(pythonNote). Sandlådan har ingen nätverksåtkomst och kan \
            bara skriva till sitt eget arbetsutrymme. Returnerar stdout, stderr \
            och slutkoden.
            """
        }
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"skill":{"type":"string","description":"Name of the enabled skill to run within."},"language":{"type":"string","enum":["bash","python"]},"code":{"type":"string","description":"The code to execute."}},"required":["skill","language","code"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: false)
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        struct Args: Decodable { let skill: String; let language: String; let code: String }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = (trimmed.isEmpty ? "{}" : trimmed).data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return error("Could not parse arguments. Expected {skill, language, code}.")
        }
        let (skills, skillNames) = resolved()
        guard let dir = skills[args.skill] else {
            let available = skillNames.isEmpty ? "none" : skillNames.joined(separator: ", ")
            return error("Unknown or disabled skill \"\(args.skill)\". Available: \(available).")
        }
        guard let language = CodeSandbox.Language(rawValue: args.language.lowercased()) else {
            return error("Unsupported language \"\(args.language)\". Use \"bash\" or \"python\".")
        }
        do {
            let result = try await sandbox.run(language: language, code: args.code, workingDirectory: dir)
            return success(result)
        } catch let e as CodeSandbox.SandboxError {
            return error(e.description)
        } catch {
            return self.error("Sandbox failure: \(error.localizedDescription)")
        }
    }

    // MARK: - Output shaping

    private func success(_ r: CodeSandbox.Result) -> ToolOutput {
        var obj: [String: Any] = [
            "stdout": r.stdout,
            "stderr": r.stderr,
            "exit_code": Int(r.exitCode),
        ]
        if r.truncated { obj["truncated"] = true }
        if r.timedOut { obj["timed_out"] = true }
        let json = (try? JSONSerialization.data(withJSONObject: obj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolOutput(outputJSON: json, isError: false, display: .markdown)
    }

    private func error(_ message: String) -> ToolOutput {
        ToolOutput(outputJSON: "{\"error\":\"\(message.escapedForJSON())\"}", isError: true, display: .markdown)
    }
}

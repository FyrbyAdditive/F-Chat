// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import ZIPFoundation
@testable import FChatCore

@Suite("SkillFrontmatter")
struct SkillFrontmatterTests {
    @Test func parsesValidManifest() throws {
        let raw = """
        ---
        name: pdf-tools
        description: Extract text and tables from PDF files.
        license: MIT
        metadata:
          version: 1.2.0
          author: someone
        ---

        # PDF Tools

        Use the bundled `scripts/extract.py`.
        """
        let f = try SkillFrontmatter.parse(raw)
        #expect(f.name == "pdf-tools")
        #expect(f.description == "Extract text and tables from PDF files.")
        #expect(f.license == "MIT")
        #expect(f.version == "1.2.0")
        #expect(f.body.contains("# PDF Tools"))
        #expect(f.body.contains("scripts/extract.py"))
    }

    @Test func parsesQuotedDescription() throws {
        let raw = """
        ---
        name: thing
        description: "A description: with a colon and \\"quotes\\"."
        ---
        body
        """
        let f = try SkillFrontmatter.parse(raw)
        #expect(f.description.contains("with a colon"))
    }

    @Test func rejectsMissingFrontmatter() {
        #expect(throws: SkillFrontmatter.ParseError.self) {
            _ = try SkillFrontmatter.parse("no frontmatter here")
        }
    }

    @Test func rejectsUnclosedFrontmatter() {
        let raw = "---\nname: x\ndescription: y\n"
        #expect(throws: SkillFrontmatter.ParseError.self) {
            _ = try SkillFrontmatter.parse(raw)
        }
    }

    @Test func rejectsMissingName() {
        let raw = "---\ndescription: y\n---\nbody"
        #expect(throws: SkillFrontmatter.ParseError.missingName) {
            _ = try SkillFrontmatter.parse(raw)
        }
    }

    @Test func rejectsInvalidNameCharacters() {
        let raw = "---\nname: Bad_Name\ndescription: y\n---\nbody"
        #expect(throws: SkillFrontmatter.ParseError.nameInvalidCharacters) {
            _ = try SkillFrontmatter.parse(raw)
        }
    }

    @Test func rejectsReservedWordInName() {
        let raw = "---\nname: claude-helper\ndescription: y\n---\nbody"
        #expect(throws: SkillFrontmatter.ParseError.self) {
            _ = try SkillFrontmatter.parse(raw)
        }
    }

    @Test func rejectsTooLongName() {
        let long = String(repeating: "a", count: 65)
        let raw = "---\nname: \(long)\ndescription: y\n---\nbody"
        #expect(throws: SkillFrontmatter.ParseError.self) {
            _ = try SkillFrontmatter.parse(raw)
        }
    }

    @Test func rejectsMissingDescription() {
        let raw = "---\nname: x\n---\nbody"
        #expect(throws: SkillFrontmatter.ParseError.missingDescription) {
            _ = try SkillFrontmatter.parse(raw)
        }
    }

    @Test func rejectsTooLongDescription() {
        let long = String(repeating: "d", count: 1025)
        let raw = "---\nname: x\ndescription: \(long)\n---\nbody"
        #expect(throws: SkillFrontmatter.ParseError.self) {
            _ = try SkillFrontmatter.parse(raw)
        }
    }

    @Test func rejectsXMLTagsInDescription() {
        let raw = "---\nname: x\ndescription: hello <script>alert(1)</script>\n---\nbody"
        #expect(throws: SkillFrontmatter.ParseError.self) {
            _ = try SkillFrontmatter.parse(raw)
        }
    }

    @Test func toleratesLeadingBlankLines() throws {
        let raw = "\n\n---\nname: x\ndescription: y\n---\nbody"
        let f = try SkillFrontmatter.parse(raw)
        #expect(f.name == "x")
    }
}

@Suite("SkillStore")
struct SkillStoreTests {
    private func makeStore() -> SkillStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-skillstore-\(UUID().uuidString)", isDirectory: true)
        return SkillStore(rootDirectory: root)
    }

    private func writeSkillDir(name: String = "demo", withScript: Bool = true) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-skillsrc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        ---
        name: \(name)
        description: A demo skill for testing.
        ---
        Run scripts/hello.sh.
        """
        try manifest.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        if withScript {
            let scripts = dir.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
            try "echo hi".write(to: scripts.appendingPathComponent("hello.sh"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func importsFromDirectory() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let src = try writeSkillDir()
        defer { try? FileManager.default.removeItem(at: src) }
        let skill = try store.importSkill(fromDirectory: src)
        #expect(skill.name == "demo")
        #expect(skill.description == "A demo skill for testing.")
        #expect(skill.sourceKind == .imported)
        // On-disk layout: SKILL.md + scripts/ + work/.
        #expect(FileManager.default.fileExists(atPath: store.manifestURL(for: skill.id).path))
        #expect(FileManager.default.fileExists(atPath: store.workingDirectory(for: skill.id).path))
        #expect(store.bundledFiles(for: skill.id).contains("scripts/hello.sh"))
    }

    @Test func importsFromZip() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let src = try writeSkillDir(name: "zipped")
        defer { try? FileManager.default.removeItem(at: src) }
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-skill-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipURL) }
        try FileManager.default.zipItem(at: src, to: zipURL)

        let skill = try store.importSkill(fromZip: zipURL)
        #expect(skill.name == "zipped")
        #expect(store.bundledFiles(for: skill.id).contains("scripts/hello.sh"))
    }

    @Test func rejectsZeroManifests() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: SkillStore.StoreError.self) {
            _ = try store.importSkill(fromDirectory: empty)
        }
    }

    @Test func rejectsMultipleManifests() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-multi-\(UUID().uuidString)", isDirectory: true)
        let sub = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = "---\nname: a\ndescription: b\n---\nx"
        try m.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try m.write(to: sub.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        #expect(throws: SkillStore.StoreError.self) {
            _ = try store.importSkill(fromDirectory: dir)
        }
    }

    @Test func createAndDelete() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let skill = try store.createSkill(name: "made", description: "Authored here.", body: "Do things.")
        #expect(skill.sourceKind == .userCreated)
        let manifestPath = store.manifestURL(for: skill.id).path
        #expect(FileManager.default.fileExists(atPath: manifestPath))
        store.deleteSkill(skill.id)
        #expect(!FileManager.default.fileExists(atPath: store.skillRootDirectory(for: skill.id).path))
    }
}

@Suite("Skill persistence")
struct SkillPersistenceTests {
    private func codec() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    @Test func skillRoundTrips() throws {
        let (e, d) = codec()
        let skill = Skill(name: "demo", description: "desc", body: "body", version: "1.0", license: "MIT", enabledByDefault: true, sourceKind: .userCreated)
        let data = try e.encode(skill)
        let back = try d.decode(Skill.self, from: data)
        // Compare the salient fields rather than whole-struct equality: ISO8601
        // date encoding drops sub-second precision, so createdAt/updatedAt
        // won't be byte-identical across a round trip.
        #expect(back.id == skill.id)
        #expect(back.name == skill.name)
        #expect(back.description == skill.description)
        #expect(back.body == skill.body)
        #expect(back.version == skill.version)
        #expect(back.license == skill.license)
        #expect(back.enabledByDefault == skill.enabledByDefault)
        #expect(back.sourceKind == skill.sourceKind)
    }

    @Test func enabledSkillsRoundTripInChatSettings() throws {
        let (e, d) = codec()
        let id = SkillID()
        let settings = ChatSettings(model: "m", providerID: .init(rawValue: "p"), enabledSkills: [id])
        let back = try d.decode(ChatSettings.self, from: try e.encode(settings))
        #expect(back.enabledSkills == [id])
    }

    @Test func oldChatSettingsWithoutEnabledSkillsDecodes() throws {
        // A state file written before the field existed. ProviderID is a
        // single-value RawRepresentable, so it encodes as a bare string.
        let json = #"{"model":"m","providerID":"p","parallelToolCalls":true,"maxToolIterations":8,"enabledBuiltInTools":[],"enabledMCPServers":[],"attachedCollections":[],"enabledServerTools":[],"responseStorageMode":"serverStored"}"#
        let (_, d) = codec()
        let back = try d.decode(ChatSettings.self, from: Data(json.utf8))
        #expect(back.enabledSkills.isEmpty)
    }

    @Test func persistedAppStateCarriesSkills() throws {
        let (e, d) = codec()
        let skill = Skill(name: "x", description: "y", body: "z")
        let state = PersistedAppState(
            providers: [], conversations: [], selectedConversationID: nil,
            promptLanguage: .english, skills: [skill]
        )
        let back = try d.decode(PersistedAppState.self, from: try e.encode(state))
        #expect(back.skills?.count == 1)
        #expect(back.skills?.first?.name == "x")
    }

    @Test func oldPersistedAppStateWithoutSkillsDecodes() throws {
        let json = #"{"version":4,"providers":[],"conversations":[],"promptLanguage":"en"}"#
        let (_, d) = codec()
        let back = try d.decode(PersistedAppState.self, from: Data(json.utf8))
        #expect(back.skills == nil)
    }
}

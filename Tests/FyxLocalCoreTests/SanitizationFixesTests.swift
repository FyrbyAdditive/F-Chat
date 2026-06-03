// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import ZIPFoundation
@testable import FyxLocalCore

@Suite("Sanitization fixes")
struct SanitizationFixesTests {

    // S1: a present-but-undecodable state.json is backed up, not silently wiped.
    @Test func corruptStateFileIsBackedUpNotLost() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("statetest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateURL = dir.appendingPathComponent("state.json")
        try Data("{ this is not valid json".utf8).write(to: stateURL)

        let store = AppStateStore(fileURL: stateURL)
        let loaded = store.load()
        #expect(loaded == nil)   // undecodable → nil (caller starts fresh)

        // The original bytes survive in a .corrupt-*.bak so data is recoverable.
        let backups = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let bak = backups.first { $0.lastPathComponent.contains(".corrupt-") }
        #expect(bak != nil)
        if let bak {
            #expect(try String(contentsOf: bak, encoding: .utf8).contains("not valid json"))
        }
    }

    @Test func missingStateFileReturnsNilWithoutBackup() {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        let store = AppStateStore(fileURL: stateURL)
        #expect(store.load() == nil)   // genuine first run, no error path
    }

    // Deleting the last provider persists an EMPTY providers array; it must
    // survive a save/load round-trip. (AppEnvironment only seeds defaults when
    // there's no state file at all — not when a saved file has zero providers,
    // which used to re-create a deleted provider on next launch.)
    @Test func emptyProvidersListSurvivesRoundTrip() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("providers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let store = AppStateStore(fileURL: stateURL)
        let state = PersistedAppState(
            providers: [],
            conversations: [],
            selectedConversationID: nil,
            promptLanguage: .english
        )
        try store.save(state)
        let loaded = try #require(store.load())
        #expect(loaded.providers.isEmpty)   // not re-seeded to defaults
    }

    // S4: chat import bounds the message count per conversation.
    @Test func chatImportCapsMessageCount() throws {
        // Build a Claude export with way more than the cap.
        let over = ChatImportLimits.maxMessagesPerConversation + 50
        var msgs = ""
        for i in 0..<over {
            let sender = i % 2 == 0 ? "human" : "assistant"
            msgs += #"{"uuid":"m\#(i)","sender":"\#(sender)","created_at":"2024-05-01T12:00:00Z","text":"m\#(i)"},"#
        }
        msgs = String(msgs.dropLast())
        let json = #"[{"uuid":"c","name":"big","created_at":"2024-05-01T12:00:00Z","updated_at":"2024-05-01T12:00:00Z","chat_messages":[\#(msgs)]}]"#
        let result = try ChatImporter.parse(jsonData: Data(json.utf8))
        let chat = try #require(result.chats.first)
        #expect(chat.messages.count <= ChatImportLimits.maxMessagesPerConversation)
    }

    // S4: a per-field char cap truncates an enormous message.
    @Test func importedMessageTruncatesHugeField() {
        let huge = String(repeating: "x", count: ChatImportLimits.maxCharsPerField + 1000)
        let m = ImportedMessage(role: .user, text: huge, createdAt: .now)
        #expect(m.text.count == ChatImportLimits.maxCharsPerField)
    }

    // S4: a skill archive that expands past the budget is rejected before extract.
    @Test func zipBombSkillArchiveIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziptest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A single highly-compressible ~300 MB entry (zeros) — well over the
        // 256 MB skill cap, but tiny on disk.
        let zipURL = dir.appendingPathComponent("bomb.zip")
        let archive = try #require(try? Archive(url: zipURL, accessMode: .create))
        let big = Data(count: 300 * 1024 * 1024)
        try archive.addEntry(with: "SKILL.md", type: .file,
                             uncompressedSize: Int64(big.count),
                             compressionMethod: .deflate,
                             provider: { pos, size in big.subdata(in: Int(pos)..<Int(pos) + size) })

        let store = SkillStore(rootDirectory: dir.appendingPathComponent("skills"))
        #expect(throws: SkillStore.StoreError.self) {
            _ = try store.importSkill(fromZip: zipURL)
        }
    }
}

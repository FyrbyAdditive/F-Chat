// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import ZIPFoundation
@testable import FChatCore

@Suite("ChatGPT import")
struct ChatGPTImportTests {
    /// A small export: a root system placeholder, then user → assistant, plus
    /// an edited branch on the user node (two children) where `current_node`
    /// points at the later branch's leaf. The active path must follow that.
    private let json = """
    [{
      "title": "Trip planning",
      "create_time": 1700000000.0,
      "update_time": 1700000600.0,
      "current_node": "n_assistant_v2",
      "mapping": {
        "n_root":   { "id": "n_root", "parent": null, "children": ["n_sys"], "message": null },
        "n_sys":    { "id": "n_sys", "parent": "n_root", "children": ["n_user"],
                      "message": { "author": {"role":"system"}, "create_time": 1700000001.0,
                                   "content": {"content_type":"text","parts":["you are helpful"]},
                                   "metadata": {"is_visually_hidden_from_conversation": true} } },
        "n_user":   { "id": "n_user", "parent": "n_sys", "children": ["n_assistant_v1","n_assistant_v2"],
                      "message": { "author": {"role":"user"}, "create_time": 1700000010.0,
                                   "content": {"content_type":"text","parts":["Plan a trip to Rome"]} } },
        "n_assistant_v1": { "id": "n_assistant_v1", "parent": "n_user", "children": [],
                      "message": { "author": {"role":"assistant"}, "create_time": 1700000020.0,
                                   "content": {"content_type":"text","parts":["OLD draft answer"]},
                                   "metadata": {"model_slug":"gpt-4o"} } },
        "n_assistant_v2": { "id": "n_assistant_v2", "parent": "n_user", "children": [],
                      "message": { "author": {"role":"assistant"}, "create_time": 1700000030.0,
                                   "content": {"content_type":"text","parts":["Day 1: Colosseum."]},
                                   "metadata": {"model_slug":"gpt-4o"} } }
      }
    }]
    """

    @Test func linearizesActiveBranchAndSkipsHiddenSystem() throws {
        let chats = try ChatGPTImporter.parse(Data(json.utf8))
        #expect(chats.count == 1)
        let chat = try #require(chats.first)
        #expect(chat.title == "Trip planning")
        #expect(chat.model == "gpt-4o")
        #expect(chat.createdAt == Date(timeIntervalSince1970: 1700000000))
        // System (hidden) dropped; the v2 assistant branch chosen, not v1.
        #expect(chat.messages.count == 2)
        #expect(chat.messages[0].role == .user)
        #expect(chat.messages[0].text == "Plan a trip to Rome")
        #expect(chat.messages[1].role == .assistant)
        #expect(chat.messages[1].text == "Day 1: Colosseum.")
        #expect(chat.messages[1].createdAt == Date(timeIntervalSince1970: 1700000030))
    }

    @Test func fallsBackToLatestBranchWithoutCurrentNode() throws {
        // Same shape but no current_node — the deepest-by-time leaf wins (v2).
        let noCurrent = json.replacingOccurrences(of: "\"current_node\": \"n_assistant_v2\",", with: "")
        let chats = try ChatGPTImporter.parse(Data(noCurrent.utf8))
        let chat = try #require(chats.first)
        #expect(chat.messages.last?.text == "Day 1: Colosseum.")
    }

    @Test func multimodalKeepsTextParts() throws {
        let mm = """
        [{
          "title": "Pic", "create_time": 1.0, "update_time": 2.0, "current_node": "a",
          "mapping": {
            "a": { "id":"a", "parent": null, "children": [],
                   "message": { "author": {"role":"user"}, "create_time": 1.0,
                     "content": {"content_type":"multimodal_text",
                       "parts":[{"content_type":"image_asset_pointer","asset_pointer":"file-x"},"What is this?"]} } }
          }
        }]
        """
        let chat = try #require(try ChatGPTImporter.parse(Data(mm.utf8)).first)
        #expect(chat.messages.count == 1)
        #expect(chat.messages[0].text == "What is this?")
    }

    @Test func emptyTextNodesDropped() throws {
        let empty = """
        [{
          "title": "Empty", "create_time": 1.0, "update_time": 2.0, "current_node": "a",
          "mapping": { "a": { "id":"a", "parent": null, "children": [],
                     "message": { "author": {"role":"assistant"}, "create_time": 1.0,
                       "content": {"content_type":"text","parts":[""]} } } }
        }]
        """
        // Whole conversation has no readable messages → skipped entirely.
        #expect(try ChatGPTImporter.parse(Data(empty.utf8)).isEmpty)
    }

    @Test func singleConversationObjectIsAccepted() throws {
        // Browser-extension / share-link exports are ONE conversation object,
        // not an array. Same per-chat `mapping` shape.
        let single = """
        {
          "title": "Just one chat", "create_time": 100.0, "update_time": 200.0, "current_node": "b",
          "mapping": {
            "a": { "id":"a", "parent": null, "children": ["b"],
                   "message": { "author": {"role":"user"}, "create_time": 100.0,
                                "content": {"content_type":"text","parts":["hello"]} } },
            "b": { "id":"b", "parent": "a", "children": [],
                   "message": { "author": {"role":"assistant"}, "create_time": 110.0,
                                "content": {"content_type":"text","parts":["hi back"]} } }
          }
        }
        """
        #expect(ChatGPTImporter.looksLikeChatGPT(try JSONSerialization.jsonObject(with: Data(single.utf8))))
        let chats = try ChatGPTImporter.parse(Data(single.utf8))
        #expect(chats.count == 1)
        #expect(chats[0].title == "Just one chat")
        #expect(chats[0].messages.map(\.text) == ["hello", "hi back"])
        // Routes through the dispatcher with no spurious skip warning.
        let result = try ChatImporter.parse(jsonData: Data(single.utf8))
        #expect(result.format == .chatGPT)
        #expect(result.chats.count == 1)
        #expect(result.warnings.isEmpty)
    }
}

@Suite("Claude import")
struct ClaudeImportTests {
    @Test func prefersContentBlocksOverTextField() throws {
        let json = """
        [{
          "uuid": "c1", "name": "Greetings",
          "created_at": "2024-05-01T12:00:00Z", "updated_at": "2024-05-01T12:05:00Z",
          "model": "claude-3-5-sonnet-20241022",
          "chat_messages": [
            { "uuid":"m1", "sender":"human", "created_at":"2024-05-01T12:00:00Z",
              "text":"legacy text", "content":[{"type":"text","text":"hello from blocks"}] },
            { "uuid":"m2", "sender":"assistant", "created_at":"2024-05-01T12:00:05.123Z",
              "text":"Hi there!" }
          ]
        }]
        """
        let chat = try #require(try ClaudeImporter.parse(Data(json.utf8)).first)
        #expect(chat.title == "Greetings")
        #expect(chat.model == "claude-3-5-sonnet-20241022")
        #expect(chat.messages.count == 2)
        #expect(chat.messages[0].role == .user)
        #expect(chat.messages[0].text == "hello from blocks")   // blocks preferred
        #expect(chat.messages[1].role == .assistant)
        #expect(chat.messages[1].text == "Hi there!")           // fractional ISO ok
        #expect(chat.messages[1].createdAt == ClaudeImporter.isoDate("2024-05-01T12:00:05.123Z"))
    }

    @Test func untitledFallback() throws {
        let json = """
        [{ "uuid":"c", "name":"", "created_at":"2024-05-01T12:00:00Z", "updated_at":"2024-05-01T12:00:00Z",
           "chat_messages": [ { "uuid":"m", "sender":"human", "created_at":"2024-05-01T12:00:00Z", "text":"hey" } ] }]
        """
        let chat = try #require(try ClaudeImporter.parse(Data(json.utf8)).first)
        #expect(chat.title == "Untitled")
    }
}

@Suite("ChatImporter dispatch + zip")
struct ChatImporterDispatchTests {
    private let chatGPT = """
    [{ "title":"t","create_time":1.0,"update_time":2.0,"current_node":"a",
       "mapping": { "a": {"id":"a","parent":null,"children":[],
         "message": {"author":{"role":"user"},"create_time":1.0,"content":{"content_type":"text","parts":["hi"]}}} } }]
    """
    private let claude = """
    [{ "uuid":"c","name":"n","created_at":"2024-05-01T12:00:00Z","updated_at":"2024-05-01T12:00:00Z",
       "chat_messages":[{"uuid":"m","sender":"human","created_at":"2024-05-01T12:00:00Z","text":"hi"}] }]
    """

    @Test func detectsChatGPT() throws {
        let r = try ChatImporter.parse(jsonData: Data(chatGPT.utf8))
        #expect(r.format == .chatGPT)
        #expect(r.chats.count == 1)
        #expect(r.messageCount == 1)
    }

    @Test func detectsClaude() throws {
        let r = try ChatImporter.parse(jsonData: Data(claude.utf8))
        #expect(r.format == .claude)
        #expect(r.chats.count == 1)
    }

    @Test func unrelatedJSONThrows() {
        #expect(throws: ChatImportError.unrecognizedFormat) {
            _ = try ChatImporter.parse(jsonData: Data(#"{"hello":"world"}"#.utf8))
        }
    }

    @Test func invalidJSONThrows() {
        #expect(throws: ChatImportError.self) {
            _ = try ChatImporter.parse(jsonData: Data("not json".utf8))
        }
    }

    @Test func readsConversationsFromZipNestedOneLevel() throws {
        // Build a zip containing dir/conversations.json and confirm it's found.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ci-\(UUID().uuidString)", isDirectory: true)
        let nested = tmp.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(claude.utf8).write(to: nested.appendingPathComponent("conversations.json"))
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("ci-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: zipURL) }
        try FileManager.default.zipItem(at: tmp, to: zipURL)

        let r = try ChatImporter.parse(fileURL: zipURL)
        #expect(r.format == .claude)
        #expect(r.chats.count == 1)
    }

    @Test func zipWithoutConversationsThrows() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ci-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tmp.appendingPathComponent("readme.txt"))
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("ci-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: zipURL) }
        try FileManager.default.zipItem(at: tmp, to: zipURL)
        #expect(throws: ChatImportError.zipMissingConversations) {
            _ = try ChatImporter.parse(fileURL: zipURL)
        }
    }

    @Test func emptyExportThrows() {
        #expect(throws: ChatImportError.emptyExport) {
            _ = try ChatImporter.parse(jsonData: Data("[]".utf8))
        }
    }
}

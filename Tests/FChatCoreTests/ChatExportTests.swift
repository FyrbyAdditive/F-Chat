// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import ZIPFoundation
@testable import FChatCore

@Suite("Chat export")
struct ChatExportTests {
    /// A two-turn conversation: a user message, then an assistant message that
    /// also carries a reasoning summary plus a tool call (which must be omitted
    /// from human formats). Fixed timestamps so output is deterministic.
    private func sampleConversation(title: String = "Trip planning") -> Conversation {
        let settings = ChatSettings(model: "gpt-4o", providerID: ProviderID(rawValue: "openai"))
        let user = Message(
            role: .user,
            contentItems: [.text("Plan a trip to Rome")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let assistant = Message(
            role: .assistant,
            contentItems: [
                .reasoningSummary("Consider season and budget."),
                .text("Day 1: Colosseum."),
                .toolCall(ToolCallRecord(id: "t1", name: "search", argumentsJSON: "{}", status: .succeeded)),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        )
        return Conversation(
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            settings: settings,
            messages: [user, assistant]
        )
    }

    @Test func markdownHasHeadingsProseAndReasoningButNoToolContent() {
        let md = ChatExporter.markdown(sampleConversation())
        #expect(md.hasPrefix("# Trip planning"))
        #expect(md.contains("## You"))
        #expect(md.contains("## Assistant"))
        #expect(md.contains("Plan a trip to Rome"))
        #expect(md.contains("Day 1: Colosseum."))
        #expect(md.contains("Reasoning"))
        #expect(md.contains("Consider season and budget."))
        // Tool calls are not part of a human transcript.
        #expect(!md.contains("search"))
        #expect(!md.contains("argumentsJSON"))
    }

    @Test func plainTextHasNoMarkdownSyntax() {
        let txt = ChatExporter.plainText(sampleConversation())
        #expect(txt.contains("YOU"))
        #expect(txt.contains("ASSISTANT"))
        #expect(txt.contains("Day 1: Colosseum."))
        #expect(txt.contains("[Reasoning]"))
        #expect(!txt.contains("##"))
        #expect(!txt.contains("search"))
    }

    @Test func jsonRoundTripsThroughTheImporter() throws {
        // The key fidelity guarantee: export JSON → re-import → same content.
        let data = try ChatExporter.json([sampleConversation()])
        let result = try ChatImporter.parse(jsonData: data)
        #expect(result.format == .fchat)
        #expect(result.chats.count == 1)
        let chat = try #require(result.chats.first)
        #expect(chat.title == "Trip planning")
        #expect(chat.model == "gpt-4o")
        #expect(chat.messages.count == 2)
        #expect(chat.messages[0].role == .user)
        #expect(chat.messages[0].text == "Plan a trip to Rome")
        #expect(chat.messages[1].role == .assistant)
        #expect(chat.messages[1].text == "Day 1: Colosseum.")
        #expect(chat.messages[1].reasoning == "Consider season and budget.")
        #expect(chat.messages[1].createdAt == Date(timeIntervalSince1970: 1_700_000_030))
    }

    @Test func docxIsAValidZipWithDocumentXMLContainingProse() throws {
        let data = try ChatExporter.docx(sampleConversation())
        let archive = try #require(try? Archive(data: data, accessMode: .read))
        #expect(archive["[Content_Types].xml"] != nil)
        let docEntry = try #require(archive["word/document.xml"])
        var xml = Data()
        _ = try archive.extract(docEntry) { xml.append($0) }
        let text = String(decoding: xml, as: UTF8.self)
        #expect(text.contains("Day 1: Colosseum."))
        #expect(text.contains("Trip planning"))
        // XML must be escaped, not raw — confirm the OOXML namespace is present.
        #expect(text.contains("w:document"))
    }

    @Test func docxEscapesXMLSpecialCharacters() throws {
        var convo = sampleConversation()
        convo.messages[0].contentItems = [.text("5 < 6 & \"quote\" > 3")]
        let data = try ChatExporter.docx(convo)
        let archive = try #require(try? Archive(data: data, accessMode: .read))
        let docEntry = try #require(archive["word/document.xml"])
        var xml = Data()
        _ = try archive.extract(docEntry) { xml.append($0) }
        let text = String(decoding: xml, as: UTF8.self)
        #expect(text.contains("5 &lt; 6 &amp; &quot;quote&quot; &gt; 3"))
    }

    @Test func multiChatExportProducesZipWithOneFilePerChat() throws {
        let chats = [
            sampleConversation(title: "Alpha"),
            sampleConversation(title: "Beta"),
            sampleConversation(title: "Gamma"),
        ]
        let bundle = try ChatExporter.export(chats, as: .markdown)
        #expect(bundle.suggestedFilename.hasSuffix(".zip"))
        let archive = try #require(try? Archive(data: bundle.data, accessMode: .read))
        let names = archive.map(\.path).sorted()
        #expect(names == ["Alpha.md", "Beta.md", "Gamma.md"])
    }

    @Test func singleChatHumanExportIsABareFileNotZip() throws {
        let bundle = try ChatExporter.export([sampleConversation(title: "Solo")], as: .markdown)
        #expect(bundle.suggestedFilename == "Solo.md")
        #expect(String(decoding: bundle.data, as: UTF8.self).hasPrefix("# Solo"))
    }

    @Test func jsonExportIsAlwaysOneCombinedFile() throws {
        let chats = [sampleConversation(title: "A"), sampleConversation(title: "B")]
        let bundle = try ChatExporter.export(chats, as: .json)
        #expect(bundle.suggestedFilename == "F-Chat export.json")
        let result = try ChatImporter.parse(jsonData: bundle.data)
        #expect(result.chats.count == 2)
    }

    @Test func emptySelectionThrows() {
        #expect(throws: ChatExportError.nothingSelected) {
            _ = try ChatExporter.export([], as: .markdown)
        }
    }

    @Test func sanitizedFilenameHandlesIllegalCharsAndEmpty() {
        #expect(ChatExporter.sanitizedFilename("a/b:c?d") == "a b c d")
        #expect(ChatExporter.sanitizedFilename("   ") == "Untitled")
        #expect(ChatExporter.sanitizedFilename("") == "Untitled")
        #expect(ChatExporter.sanitizedFilename(".hidden") == "hidden")
        #expect(ChatExporter.sanitizedFilename("normal title") == "normal title")
    }

    @Test func duplicateTitlesGetUniqueFilenamesInZip() throws {
        let chats = [
            sampleConversation(title: "Same"),
            sampleConversation(title: "Same"),
            sampleConversation(title: "Same"),
        ]
        let bundle = try ChatExporter.export(chats, as: .plainText)
        let archive = try #require(try? Archive(data: bundle.data, accessMode: .read))
        let names = Set(archive.map(\.path))
        #expect(names == ["Same.txt", "Same 2.txt", "Same 3.txt"])
    }

    @Test func messagesWithOnlyToolContentAreSkippedInHumanFormats() {
        let settings = ChatSettings(model: "m", providerID: ProviderID(rawValue: "p"))
        let toolOnly = Message(
            role: .assistant,
            contentItems: [.toolCall(ToolCallRecord(id: "t", name: "x", argumentsJSON: "{}", status: .succeeded))],
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let real = Message(role: .user, contentItems: [.text("hi")], createdAt: Date(timeIntervalSince1970: 2))
        let convo = Conversation(title: "T", settings: settings, messages: [toolOnly, real])
        let md = ChatExporter.markdown(convo)
        #expect(md.contains("hi"))
        #expect(!md.contains("Assistant"))  // the tool-only assistant turn is dropped
    }
}

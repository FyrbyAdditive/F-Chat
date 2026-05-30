// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatProviders
import FChatWeb
@testable import FChatTools

@Suite("WebSearchTool")
struct WebSearchToolTests {
    @Test func happyPathProducesJSONResults() async throws {
        let stub = StubSearch(results: [
            WebSearchResult(title: "Swift.org", url: URL(string: "https://www.swift.org/")!, snippet: "Swift home"),
            WebSearchResult(title: "Apple Developer", url: URL(string: "https://developer.apple.com/swift/")!, snippet: "Apple"),
        ])
        let tool = WebSearchTool(provider: stub)
        let output = try await tool.invoke(arguments: #"{"query":"swift","max_results":2}"#)
        #expect(output.isError == false)
        #expect(output.outputJSON.contains("Swift.org"))
        #expect(output.outputJSON.contains("Apple Developer"))
        #expect(await stub.lastQuery == "swift")
    }

    @Test func badArgumentsReturnsErrorOutput() async throws {
        // Bad args should surface as a structured error result (not throw)
        // so the model receives a hint on the next iteration instead of the
        // turn dying.
        let tool = WebSearchTool(provider: StubSearch(results: []))
        let output = try await tool.invoke(arguments: "not json")
        #expect(output.isError == true)
        #expect(output.outputJSON.contains("Could not parse arguments"))
    }

    @Test func emptyQueryReturnsErrorOutput() async throws {
        let tool = WebSearchTool(provider: StubSearch(results: []))
        let output = try await tool.invoke(arguments: #"{"query":"   "}"#)
        #expect(output.isError == true)
        #expect(output.outputJSON.contains("query is empty"))
    }

    @Test func definitionMentionsSwedishInSwedishMode() {
        let tool = WebSearchTool(provider: StubSearch(results: []))
        #expect(tool.definition(for: .swedish).description.contains("Sök"))
        #expect(tool.definition(for: .english).description.contains("Search"))
    }
}

actor StubSearch: WebSearchProvider {
    nonisolated let displayName = "stub"
    let results: [WebSearchResult]
    private(set) var lastQuery: String?
    private(set) var lastLimit: Int?
    init(results: [WebSearchResult]) { self.results = results }
    func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        lastQuery = query
        lastLimit = maxResults
        return results
    }
}

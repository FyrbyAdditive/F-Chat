// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatWeb

@Suite("DuckDuckGo parser")
struct DuckDuckGoParserTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "html"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func parsesBasicFixture() throws {
        let html = try fixture("ddg_results_basic")
        let results = try DuckDuckGoProvider.parseResults(html: html, limit: 10)
        #expect(results.count == 4) // including the ad-styled one — caller can filter if it wants
        #expect(results[0].title == "The Swift Programming Language")
        #expect(results[0].url.absoluteString == "https://www.swift.org/")
        #expect(results[0].snippet.contains("powerful"))
        #expect(results[1].url.host == "developer.apple.com")
        #expect(results[3].url.host == "en.wikipedia.org")
    }

    @Test func limitTrimsResults() throws {
        let html = try fixture("ddg_results_basic")
        let results = try DuckDuckGoProvider.parseResults(html: html, limit: 2)
        #expect(results.count == 2)
    }

    @Test func emptyResultsPageYieldsEmpty() throws {
        let html = try fixture("ddg_no_results")
        let results = try DuckDuckGoProvider.parseResults(html: html, limit: 10)
        #expect(results.isEmpty)
    }

    @Test func resolveRedirectExtractsRealURL() {
        let resolved = DuckDuckGoProvider.resolveDuckDuckGoURL("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fpath&rut=x")
        #expect(resolved?.absoluteString == "https://example.org/path")
    }

    @Test func resolvePlainURLPassesThrough() {
        let resolved = DuckDuckGoProvider.resolveDuckDuckGoURL("https://en.wikipedia.org/wiki/Swift")
        #expect(resolved?.host == "en.wikipedia.org")
    }
}

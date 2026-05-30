// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import FChatCore
import FChatProviders
import FChatWeb
@testable import FChatTools

/// Counts how many times `extract` is invoked so we can assert the cache
/// intercepts repeat fetches of the same URL.
private actor CountingExtractor: PageExtractor {
    let body: String
    private(set) var invocations: Int = 0

    init(body: String) { self.body = body }

    func extract(url: URL, timeout: TimeInterval) async throws -> ExtractedPage {
        invocations += 1
        return ExtractedPage(
            url: url,
            title: "T",
            byline: nil,
            excerpt: nil,
            content: body
        )
    }
}

@Suite("WebFetchTool")
struct WebFetchToolTests {

    @Test func cacheHitSkipsExtractorOnSecondFetch() async throws {
        let extractor = CountingExtractor(body: "hello world")
        let cache = WebFetchCache()
        let tool = WebFetchTool(extractor: extractor, cache: cache)
        let args = #"{"url":"https://example.com/article"}"#

        let first = try await tool.invoke(arguments: args)
        #expect(first.isError == false)
        #expect(await extractor.invocations == 1)

        let second = try await tool.invoke(arguments: args)
        #expect(second.isError == false)
        // Cache hit: extractor was NOT called again.
        #expect(await extractor.invocations == 1)
        // Both responses describe the same page. JSONEncoder key order isn't
        // guaranteed across calls, so compare semantically by re-parsing.
        let firstParsed = try JSONSerialization.jsonObject(with: Data(first.outputJSON.utf8)) as? [String: Any]
        let secondParsed = try JSONSerialization.jsonObject(with: Data(second.outputJSON.utf8)) as? [String: Any]
        #expect(firstParsed?["content"] as? String == "hello world")
        #expect(secondParsed?["content"] as? String == "hello world")
        #expect(firstParsed?["url"] as? String == secondParsed?["url"] as? String)
    }

    @Test func differentURLBypassesCache() async throws {
        let extractor = CountingExtractor(body: "x")
        let cache = WebFetchCache()
        let tool = WebFetchTool(extractor: extractor, cache: cache)
        _ = try await tool.invoke(arguments: #"{"url":"https://example.com/a"}"#)
        _ = try await tool.invoke(arguments: #"{"url":"https://example.com/b"}"#)
        #expect(await extractor.invocations == 2)
    }

    @Test func clipHeadAndTailWhenContentTooLong() {
        let long = String(repeating: "A", count: 50_000)
        let page = ExtractedPage(
            url: URL(string: "https://e.example")!,
            title: nil, byline: nil, excerpt: nil,
            content: long
        )
        let clipped = WebFetchTool.clip(page)
        // Head + tail + marker, much shorter than original.
        #expect(clipped.content.count < page.content.count / 2)
        #expect(clipped.content.hasPrefix(String(repeating: "A", count: 100)))
        #expect(clipped.content.contains("[...content truncated by F-Chat"))
        #expect(clipped.content.hasSuffix(String(repeating: "A", count: 100)))
    }

    @Test func clipPreservesShortContentUntouched() {
        let short = "small body"
        let page = ExtractedPage(
            url: URL(string: "https://e.example")!,
            title: nil, byline: nil, excerpt: nil,
            content: short
        )
        let clipped = WebFetchTool.clip(page)
        #expect(clipped.content == short)
    }

    @Test func noCacheArgumentStillWorks() async throws {
        // Existing call sites that don't pass `cache:` should keep working.
        let extractor = CountingExtractor(body: "ok")
        let tool = WebFetchTool(extractor: extractor)
        let output = try await tool.invoke(arguments: #"{"url":"https://x"}"#)
        #expect(output.isError == false)
        #expect(await extractor.invocations == 1)
    }
}

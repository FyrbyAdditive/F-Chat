// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatWeb

@Suite("WebFetchCache")
struct WebFetchCacheTests {

    private func makePage(_ url: String, content: String = "body") -> ExtractedPage {
        ExtractedPage(
            url: URL(string: url)!,
            title: nil,
            byline: nil,
            excerpt: nil,
            content: content
        )
    }

    @Test func putThenGetRoundTrips() async {
        let cache = WebFetchCache()
        let page = makePage("https://example.com/a")
        await cache.put("https://example.com/a", page)
        let got = await cache.get("https://example.com/a")
        #expect(got?.content == "body")
    }

    @Test func missReturnsNil() async {
        let cache = WebFetchCache()
        let got = await cache.get("https://nothing.example/")
        #expect(got == nil)
    }

    @Test func clearRemovesEverything() async {
        let cache = WebFetchCache()
        await cache.put("a", makePage("https://a.example"))
        await cache.put("b", makePage("https://b.example"))
        await cache.clear()
        let aCount = await cache.count
        #expect(aCount == 0)
    }

    @Test func lruEvictsOldestWhenOverLimit() async {
        let cache = WebFetchCache(limit: 3)
        await cache.put("u1", makePage("https://u1"))
        await cache.put("u2", makePage("https://u2"))
        await cache.put("u3", makePage("https://u3"))
        // Touch u1 + u2 so u3 is now the oldest by lastAccess.
        _ = await cache.get("u1")
        _ = await cache.get("u2")
        // Inserting u4 should evict u3.
        await cache.put("u4", makePage("https://u4"))
        let u1 = await cache.get("u1")
        let u2 = await cache.get("u2")
        let u3 = await cache.get("u3")
        let u4 = await cache.get("u4")
        #expect(u1 != nil)
        #expect(u2 != nil)
        #expect(u3 == nil, "u3 should have been LRU-evicted")
        #expect(u4 != nil)
    }

    @Test func putOverwritesExistingEntry() async {
        let cache = WebFetchCache()
        await cache.put("u", makePage("https://u", content: "v1"))
        await cache.put("u", makePage("https://u", content: "v2"))
        let got = await cache.get("u")
        #expect(got?.content == "v2")
    }
}

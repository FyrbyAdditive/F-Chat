// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import SwiftSoup

public struct DuckDuckGoProvider: WebSearchProvider {
    public let displayName: String = "DuckDuckGo"
    public let endpoint: URL
    public let session: URLSession
    public let rateLimiter: RateLimiter
    public let userAgent: String

    public init(
        endpoint: URL = URL(string: "https://html.duckduckgo.com/html/")!,
        session: URLSession = .shared,
        rateLimiter: RateLimiter = RateLimiter(minimumInterval: 1.0),
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    ) {
        self.endpoint = endpoint
        self.session = session
        self.rateLimiter = rateLimiter
        self.userAgent = userAgent
    }

    public func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebSearchError.emptyQuery }

        try await rateLimiter.waitForSlot()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyString = "q=\(percentEscape(trimmed))&kl=us-en"
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 202 { throw WebSearchError.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                throw WebSearchError.httpStatus(http.statusCode)
            }
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.parseFailure("non-utf8 response")
        }
        return try Self.parseResults(html: html, limit: maxResults)
    }

    /// Pure HTML → results parser, exposed for fixture-based tests.
    public static func parseResults(html: String, limit: Int) throws -> [WebSearchResult] {
        let doc: Document
        do { doc = try SwiftSoup.parse(html) } catch {
            throw WebSearchError.parseFailure("swiftsoup parse error: \(error.localizedDescription)")
        }

        let resultNodes: Elements
        do { resultNodes = try doc.select("div.result, div.web-result, div.results_links") }
        catch { throw WebSearchError.parseFailure("selector error: \(error.localizedDescription)") }

        var output: [WebSearchResult] = []
        for node in resultNodes.array() {
            if output.count >= limit { break }
            guard let parsed = try? parseSingle(node) else { continue }
            output.append(parsed)
        }
        return output
    }

    private static func parseSingle(_ node: Element) throws -> WebSearchResult? {
        let titleEl = try node.select("a.result__a, a.result-link").first()
        guard let titleEl else { return nil }
        let title = try titleEl.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let href = try titleEl.attr("href")
        guard let resolved = resolveDuckDuckGoURL(href) else { return nil }

        let snippet: String
        if let snippetEl = try node.select("a.result__snippet, div.result__snippet, .result-snippet").first() {
            snippet = try snippetEl.text().trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            snippet = ""
        }
        return WebSearchResult(title: title, url: resolved, snippet: snippet)
    }

    /// DuckDuckGo HTML wraps actual URLs in a redirect like
    /// `//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com`.
    static func resolveDuckDuckGoURL(_ href: String) -> URL? {
        let normalized: String
        if href.hasPrefix("//") {
            normalized = "https:" + href
        } else {
            normalized = href
        }
        guard let components = URLComponents(string: normalized) else { return nil }
        if let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return URL(string: uddg)
        }
        return URL(string: normalized)
    }

    private func percentEscape(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

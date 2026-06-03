// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import FyxLocalProviders
import FyxLocalWeb

public struct WebFetchTool: Tool {
    public let name = "web_fetch"
    public let extractor: any PageExtractor
    public let defaultTimeout: TimeInterval
    /// Optional per-session cache of fetched pages. When present, the model
    /// can re-fetch the same URL without paying network latency or the
    /// (clipped) token cost twice. Nil in tests / dev paths that don't
    /// want caching.
    public let cache: WebFetchCache?

    /// Maximum head/tail char counts when clipping a large page body so the
    /// `outputJSON` doesn't blow the context budget. A 50k-token article
    /// becomes ~3k tokens after clipping; the full body lives in `cache`
    /// for re-fetch.
    public static let headChars = 8_000
    public static let tailChars = 2_000

    /// Whether to run the async DNS-resolution SSRF check (reject hostnames that
    /// resolve to internal IPs). On in production; tests pass `false` to stay
    /// hermetic — they still exercise the synchronous scheme/literal-IP guard.
    public let resolveHosts: Bool

    public init(
        extractor: any PageExtractor,
        defaultTimeout: TimeInterval = 12.0,
        cache: WebFetchCache? = nil,
        resolveHosts: Bool = true
    ) {
        self.extractor = extractor
        self.defaultTimeout = defaultTimeout
        self.cache = cache
        self.resolveHosts = resolveHosts
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description = PromptStrings.string("tool.web_fetch.desc", language)
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"url":{"type":"string","format":"uri"}},"required":["url"],"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: true)
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        struct Args: Decodable { let url: String }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.isEmpty ? "{}" : trimmed
        guard let data = normalised.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Args.self, from: data) else {
            let message = #"{"error":"Could not parse arguments. Expected {\"url\": string}. Got: \#(arguments.escapedForJSONInline())"}"#
            return ToolOutput(outputJSON: message, isError: true, display: .markdown)
        }
        let urlString = parsed.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            return ToolOutput(outputJSON: #"{"error":"Invalid URL: \#(parsed.url.escapedForJSONInline())"}"#, isError: true, display: .markdown)
        }

        // SSRF guard: the URL comes from the model, so block file://, non-HTTP
        // schemes, localhost/loopback/link-local/private hosts, and the cloud
        // metadata address — including hostnames that *resolve* to such IPs.
        if case .failure(let reason) = URLSafety.validatePublicHTTP(url) {
            return ToolOutput(outputJSON: #"{"error":"Refused to fetch \#(parsed.url.escapedForJSONInline()): \#("\(reason)".escapedForJSONInline())"}"#, isError: true, display: .markdown)
        }
        if resolveHosts, await URLSafety.hostResolvesToPublicOnly(url) == false {
            return ToolOutput(outputJSON: #"{"error":"Refused to fetch \#(parsed.url.escapedForJSONInline()): the host resolves to a local or private address"}"#, isError: true, display: .markdown)
        }

        // Cache hit: skip the network entirely.
        if let cache, let cached = await cache.get(urlString) {
            let clipped = Self.clip(cached)
            let json = (try? JSONEncoder().encode(clipped)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return ToolOutput(outputJSON: json, display: .markdown)
        }

        do {
            let extracted = try await extractor.extract(url: url, timeout: defaultTimeout)
            // Store the full untruncated body so a re-fetch on the same URL
            // can serve from cache.
            if let cache {
                await cache.put(urlString, extracted)
            }
            let clipped = Self.clip(extracted)
            let json = try JSONEncoder().encode(clipped)
            return ToolOutput(outputJSON: String(data: json, encoding: .utf8) ?? "{}", display: .markdown)
        } catch {
            let message = #"{"error":"web_fetch failed: \#(error.localizedDescription.escapedForJSONInline())"}"#
            return ToolOutput(outputJSON: message, isError: true, display: .markdown)
        }
    }

    /// Clip an extracted page's `content` to head+tail with a marker noting
    /// the elision. Pages under the combined threshold pass through as-is.
    /// Static + public so tests can hit it directly.
    public static func clip(_ page: ExtractedPage) -> ExtractedPage {
        let total = page.content.count
        guard total > headChars + tailChars + 200 else { return page }
        let head = String(page.content.prefix(headChars))
        let tail = String(page.content.suffix(tailChars))
        let marker = "\n\n[...content truncated by FyxLocal (\(total) chars total); call web_fetch again on the same URL to retrieve from cache...]\n\n"
        var clipped = page
        clipped.content = head + marker + tail
        return clipped
    }
}

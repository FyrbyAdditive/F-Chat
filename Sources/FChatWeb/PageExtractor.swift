// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
#if canImport(WebKit)
import WebKit
#endif

public struct ExtractedPage: Sendable, Hashable, Codable {
    public var url: URL
    public var title: String?
    public var byline: String?
    public var excerpt: String?
    public var content: String
    public var lengthChars: Int

    public init(url: URL, title: String?, byline: String?, excerpt: String?, content: String) {
        self.url = url
        self.title = title
        self.byline = byline
        self.excerpt = excerpt
        self.content = content
        self.lengthChars = content.count
    }
}

public enum PageExtractorError: Error, Sendable, Equatable {
    case navigationFailed(String)
    case timedOut
    case readabilityUnavailable
    case scriptError(String)
    case noContent
}

public protocol PageExtractor: Sendable {
    func extract(url: URL, timeout: TimeInterval) async throws -> ExtractedPage
}

#if canImport(WebKit)
public final class WebKitPageExtractor: PageExtractor, @unchecked Sendable {
    private let readabilityScript: String

    public init(readabilityScript: String? = nil) {
        if let injected = readabilityScript {
            self.readabilityScript = injected
        } else if let url = Bundle.module.url(forResource: "Readability", withExtension: "js"),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) {
            self.readabilityScript = text
        } else {
            self.readabilityScript = ""
        }
    }

    public func extract(url: URL, timeout: TimeInterval = 12.0) async throws -> ExtractedPage {
        try await withThrowingTaskGroup(of: ExtractedPage.self) { group in
            group.addTask { try await self.driveWebView(url: url) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw PageExtractorError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    @MainActor
    private func driveWebView(url: URL) async throws -> ExtractedPage {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) F-Chat/0.1"

        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate

        webView.load(URLRequest(url: url))
        try await delegate.waitUntilFinished()

        if !readabilityScript.isEmpty && !readabilityScript.contains("__fchat_readability_placeholder") {
            do { _ = try await webView.evaluateJavaScript(readabilityScript) }
            catch { throw PageExtractorError.scriptError(String(describing: error)) }
            let evalScript = "(function(){const doc=document.cloneNode(true);const r=new Readability(doc).parse();return JSON.stringify(r||{});})();"
            guard let json = try await webView.evaluateJavaScript(evalScript) as? String,
                  let data = json.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(ReadabilityResult.self, from: data) else {
                throw PageExtractorError.readabilityUnavailable
            }
            return ExtractedPage(
                url: url,
                title: parsed.title,
                byline: parsed.byline,
                excerpt: parsed.excerpt,
                content: parsed.textContent ?? ""
            )
        } else {
            // Fallback: scrape body innerText
            let title = (try? await webView.evaluateJavaScript("document.title")) as? String
            let body = (try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
            guard !body.isEmpty else { throw PageExtractorError.noContent }
            return ExtractedPage(url: url, title: title, byline: nil, excerpt: nil, content: body)
        }
    }
}

private struct ReadabilityResult: Decodable {
    let title: String?
    let byline: String?
    let excerpt: String?
    let textContent: String?
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var error: Error?

    func waitUntilFinished() async throws {
        if finished { return }
        if let error { throw error }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = PageExtractorError.navigationFailed(error.localizedDescription)
        continuation?.resume(throwing: self.error!)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = PageExtractorError.navigationFailed(error.localizedDescription)
        continuation?.resume(throwing: self.error!)
        continuation = nil
    }
}
#endif

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// A `URLSession` delegate that refuses HTTP redirects whose target is not a
/// public http/https host. Used for OAuth + MCP HTTP traffic so a hostile or
/// MITM'd server can't 30x-bounce a request (carrying the `Authorization`
/// header) to `file://`, `localhost`, the cloud-metadata address, or an
/// internal/private IP. Refusing (handler(nil)) surfaces the pre-redirect
/// response instead of silently following.
public final class SSRFGuardingSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    public override init() { super.init() }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, case .success = URLSafety.validatePublicHTTP(url) else {
            completionHandler(nil)   // refuse the redirect
            return
        }
        completionHandler(request)
    }

    /// Build a `URLSession` whose redirects are SSRF-guarded. The delegate is
    /// retained by the session per `URLSession` semantics.
    public static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: SSRFGuardingSessionDelegate(), delegateQueue: nil)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// RFC 9728 protected-resource-metadata document. The MCP server tells
/// us which OAuth authorization server(s) issue tokens for it.
public struct ProtectedResourceMetadata: Sendable, Equatable {
    /// Identifier of the protected resource.
    public let resource: String?
    /// URLs of authorization servers that issue tokens for this
    /// resource. We pick the first one that responds to the
    /// `oauth-authorization-server` discovery call.
    public let authorizationServers: [URL]

    /// Fetches `<resource>/.well-known/oauth-protected-resource` and
    /// parses it. Throws on transport errors, non-2xx HTTP responses,
    /// or missing required fields.
    public static func fetch(
        resource: URL,
        session: URLSession
    ) async throws -> ProtectedResourceMetadata {
        let url = wellKnownURL(for: resource)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.discoveryFailed(reason: "non-HTTP response from \(url)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.discoveryFailed(reason: "HTTP \(http.statusCode) from \(url)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError.discoveryFailed(reason: "non-JSON body from \(url)")
        }
        let resourceID = json["resource"] as? String
        let servers = (json["authorization_servers"] as? [String]) ?? []
        let parsed = servers.compactMap { URL(string: $0) }
        guard !parsed.isEmpty else {
            throw AuthError.missingMetadata(field: "authorization_servers")
        }
        return ProtectedResourceMetadata(
            resource: resourceID,
            authorizationServers: parsed
        )
    }

    /// Fetch + parse a protected-resource-metadata document from an
    /// explicit URL (e.g. one extracted from a `WWW-Authenticate`
    /// header's `resource_metadata` parameter).
    public static func fetch(
        at url: URL,
        session: URLSession
    ) async throws -> ProtectedResourceMetadata {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.discoveryFailed(reason: "non-HTTP response from \(url)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.discoveryFailed(reason: "HTTP \(http.statusCode) from \(url)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError.discoveryFailed(reason: "non-JSON body from \(url)")
        }
        let resourceID = json["resource"] as? String
        let servers = (json["authorization_servers"] as? [String]) ?? []
        let parsed = servers.compactMap { URL(string: $0) }
        guard !parsed.isEmpty else {
            throw AuthError.missingMetadata(field: "authorization_servers")
        }
        return ProtectedResourceMetadata(resource: resourceID, authorizationServers: parsed)
    }

    /// Resolves `<resource-root>/.well-known/oauth-protected-resource`
    /// preserving any path the user typed at the MCP server URL — we
    /// rebase to the host root because `.well-known` paths are
    /// host-scoped per the RFC.
    static func wellKnownURL(for resource: URL) -> URL {
        var components = URLComponents()
        components.scheme = resource.scheme
        components.host = resource.host
        components.port = resource.port
        components.path = "/.well-known/oauth-protected-resource"
        return components.url ?? resource
    }

    /// Path-scoped variant: `<host>/.well-known/oauth-protected-resource<path>`.
    /// Some servers host per-resource metadata under the resource's
    /// path (MCP spec revision allows this). Returns nil when the
    /// resource URL has no meaningful path.
    public static func pathScopedWellKnownURL(for resource: URL) -> URL? {
        let path = resource.path
        guard !path.isEmpty, path != "/" else { return nil }
        var components = URLComponents()
        components.scheme = resource.scheme
        components.host = resource.host
        components.port = resource.port
        components.path = "/.well-known/oauth-protected-resource" + (path.hasPrefix("/") ? path : "/" + path)
        return components.url
    }

    /// Parse the `resource_metadata="<url>"` parameter out of a
    /// `WWW-Authenticate` header value (RFC 9728 §5.1). Returns nil
    /// when absent or unparseable.
    public static func resourceMetadataURL(fromWWWAuthenticate header: String) -> URL? {
        // The header looks like:
        //   Bearer error="invalid_request", resource_metadata="https://…"
        // Find resource_metadata= and read the quoted (or bare) value.
        guard let range = header.range(of: "resource_metadata") else { return nil }
        var rest = header[range.upperBound...]
        // Skip optional whitespace + `=`.
        while let first = rest.first, first == " " || first == "=" {
            rest = rest.dropFirst()
        }
        let value: Substring
        if rest.first == "\"" {
            rest = rest.dropFirst()
            if let endQuote = rest.firstIndex(of: "\"") {
                value = rest[rest.startIndex..<endQuote]
            } else {
                value = rest
            }
        } else {
            // Bare token up to the next comma or whitespace.
            let end = rest.firstIndex(where: { $0 == "," || $0 == " " }) ?? rest.endIndex
            value = rest[rest.startIndex..<end]
        }
        return URL(string: String(value))
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public struct MCPServerRecord: Identifiable, Sendable, Hashable, Codable {
    public let id: MCPServerID
    public var displayName: String
    public var transport: MCPTransportConfig
    public var enabled: Bool

    public init(
        id: MCPServerID,
        displayName: String,
        transport: MCPTransportConfig,
        enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.enabled = enabled
    }
}

public enum MCPTransportConfig: Sendable, Hashable, Codable {
    case stdio(StdioConfig)
    case http(HTTPConfig)

    public struct StdioConfig: Sendable, Hashable, Codable {
        public var command: String
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: String?

        public init(
            command: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            workingDirectory: String? = nil
        ) {
            self.command = command
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
        }
    }

    /// How an HTTP MCP server authenticates when OAuth isn't used.
    /// The actual token/credential is never stored here — it lives in
    /// the Keychain, keyed by server id. This enum + the (non-secret)
    /// email for `.basic` is all that persists to state.json.
    public enum HTTPAuthMode: String, Sendable, Hashable, Codable {
        /// No automatic Authorization header (use raw `headers` if needed).
        case none
        /// `Authorization: Bearer <token>` — service keys, simple bearer.
        case bearer
        /// `Authorization: Basic base64(email:token)` — e.g. Atlassian
        /// personal API tokens.
        case basic
    }

    public struct HTTPConfig: Sendable, Hashable, Codable {
        public var url: URL
        public var headers: [String: String]
        public var useOAuth: Bool
        /// Non-OAuth auth scheme. The secret is in the Keychain; for
        /// `.basic` the (non-secret) email lives in `basicAuthEmail`.
        public var authMode: HTTPAuthMode
        /// Email/username for `.basic` auth. Not a secret; persisted here.
        public var basicAuthEmail: String?
        /// Pre-registered OAuth client_id. Leave nil and the coordinator
        /// will perform RFC 7591 dynamic client registration on first
        /// sign-in (assuming the authorization server supports it).
        public var oauthClientID: String?
        /// Override the OAuth authorization server URL. Defaults to whatever
        /// the MCP server advertises via RFC 9728 protected-resource-metadata.
        public var oauthAuthorizationServerURL: URL?
        /// Space-separated scope list to request. nil → the auth server's
        /// default scope set.
        public var oauthScopes: String?
        /// RFC 8707 resource indicator value. nil → defaults to `url`
        /// (the MCP server endpoint), which is the right answer in
        /// almost every case.
        public var oauthResourceIndicator: URL?

        public init(
            url: URL,
            headers: [String: String] = [:],
            useOAuth: Bool = false,
            authMode: HTTPAuthMode = .none,
            basicAuthEmail: String? = nil,
            oauthClientID: String? = nil,
            oauthAuthorizationServerURL: URL? = nil,
            oauthScopes: String? = nil,
            oauthResourceIndicator: URL? = nil
        ) {
            self.url = url
            self.headers = headers
            self.useOAuth = useOAuth
            self.authMode = authMode
            self.basicAuthEmail = basicAuthEmail
            self.oauthClientID = oauthClientID
            self.oauthAuthorizationServerURL = oauthAuthorizationServerURL
            self.oauthScopes = oauthScopes
            self.oauthResourceIndicator = oauthResourceIndicator
        }

        // Custom Decodable so older state files (pre-authMode) load
        // cleanly — authMode defaults to .none, basicAuthEmail to nil.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.url = try c.decode(URL.self, forKey: .url)
            self.headers = try c.decode([String: String].self, forKey: .headers, default: [:])
            self.useOAuth = try c.decode(Bool.self, forKey: .useOAuth, default: false)
            self.authMode = try c.decode(HTTPAuthMode.self, forKey: .authMode, default: .none)
            self.basicAuthEmail = try c.decodeIfPresent(String.self, forKey: .basicAuthEmail)
            self.oauthClientID = try c.decodeIfPresent(String.self, forKey: .oauthClientID)
            self.oauthAuthorizationServerURL = try c.decodeIfPresent(URL.self, forKey: .oauthAuthorizationServerURL)
            self.oauthScopes = try c.decodeIfPresent(String.self, forKey: .oauthScopes)
            self.oauthResourceIndicator = try c.decodeIfPresent(URL.self, forKey: .oauthResourceIndicator)
        }
    }
}

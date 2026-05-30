// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import Observation
import FChatCore
import FChatMCP
import FChatTools

/// Owns the live `MCPClient` connections for every user-configured MCP
/// server, plus the `MCPToolAdapter` instances those clients spawned into
/// the shared `ToolRegistry`. Connection is lazy: nothing happens at app
/// launch; the first chat send triggers `ensureLoaded`, which walks the
/// enabled-server list in parallel and connects each.
///
/// Lifecycle responsibilities:
/// - `ensureLoaded(servers:)` — idempotent per session; called from
///   `ChatViewModel.send` before reading the tool registry's definitions.
/// - `connect(_:)` — used by Settings → MCP "Test connection / refresh
///   tools" buttons and by ensureLoaded.
/// - `disconnect(_:)` — clean shutdown + unregister tools. Called when a
///   server is toggled off or deleted from Settings.
/// - `reconnect(_:)` — convenience: disconnect followed by connect with
///   the new config. Used when the user edits a server in Settings.
@MainActor
@Observable
final class MCPRegistry {
    /// Per-server status, exposed for UI rendering. Observable so cards
    /// re-render automatically when `connect` flips state.
    enum Status: Equatable {
        case disconnected
        case connecting
        case ready(toolCount: Int)
        case failed(String)
    }

    private struct Entry {
        let client: MCPClient
        var adapterNames: [String]
    }

    private var entries: [MCPServerID: Entry] = [:]
    private(set) var status: [MCPServerID: Status] = [:]
    private let toolRegistry: ToolRegistry
    /// True after `ensureLoaded` has run once this session — subsequent
    /// calls return immediately so the chat send path stays O(1).
    private var loadedOnce: Bool = false
    /// OAuth coordinator for HTTP servers with `useOAuth = true`.
    /// Optional so test paths can construct a registry without one.
    let oauthCoordinator: OAuthCoordinator?

    /// Reads non-OAuth static auth tokens (bearer / basic) from the
    /// Keychain when building the Authorization header. Optional so test
    /// paths can omit it.
    private let secretStore: (any SecretStore)?

    init(
        toolRegistry: ToolRegistry,
        oauthCoordinator: OAuthCoordinator? = nil,
        secretStore: (any SecretStore)? = nil
    ) {
        self.toolRegistry = toolRegistry
        self.oauthCoordinator = oauthCoordinator
        self.secretStore = secretStore
    }

    /// Mark a server's card as failed with a reason. Used by the
    /// AppEnvironment sign-in helper so an interactive-auth failure
    /// shows in the always-visible card header, not just the form's
    /// inline error line.
    func setFailedStatus(_ id: MCPServerID, reason: String) {
        status[id] = .failed(reason)
    }

    /// Idempotent: walks the enabled-server list once per session and
    /// connects each (sequentially, so we don't spawn N subprocesses
    /// before the first chat turn even begins). Subsequent calls are
    /// no-ops. Tools land in the shared `toolRegistry` via
    /// `MCPToolAdapter` so the existing chat-turn machinery picks them
    /// up without further plumbing.
    ///
    /// Sequential rather than parallel because (a) most users will have
    /// at most a handful of servers, (b) failures don't block each
    /// other — we surface per-server status into the UI — and (c)
    /// keeping it ordered makes the first-load latency predictable.
    func ensureLoaded(servers: [MCPServerRecord]) async {
        guard !loadedOnce else { return }
        loadedOnce = true
        for record in servers where record.enabled {
            await connect(record)
        }
    }

    /// Connect (or reconnect) to a single server. Spawns the appropriate
    /// transport, runs the MCP `initialize` handshake, fetches the tool
    /// list, and registers an `MCPToolAdapter` per tool. Re-entrant: if
    /// already connected we shut down the previous client first.
    func connect(_ record: MCPServerRecord) async {
        await disconnect(record.id)
        status[record.id] = .connecting

        let transport: any MCPTransport
        switch record.transport {
        case .stdio(let config):
            let stdio = StdioMCPTransport(
                command: config.command,
                arguments: config.arguments,
                environment: config.environment,
                workingDirectory: config.workingDirectory
            )
            do {
                try await stdio.start()
            } catch {
                status[record.id] = .failed(Self.describe(error))
                return
            }
            transport = stdio
        case .http(let config):
            var headers = config.headers
            if config.useOAuth {
                guard let coordinator = oauthCoordinator else {
                    status[record.id] = .failed("OAuth requested but no coordinator configured")
                    return
                }
                do {
                    let token = try await coordinator.accessToken(
                        for: record.id,
                        resource: config.url,
                        httpConfig: config
                    )
                    headers["Authorization"] = "Bearer \(token)"
                } catch {
                    status[record.id] = .failed(Self.describe(error))
                    return
                }
            } else if let authHeader = await staticAuthorizationHeader(for: record.id, config: config) {
                // Non-OAuth bearer / basic auth — token from Keychain.
                headers["Authorization"] = authHeader
            }
            let http = HTTPMCPTransport(
                url: config.url,
                extraHeaders: headers
            )
            if config.useOAuth, let coordinator = oauthCoordinator {
                let serverID = record.id
                let resource = config.url
                let httpConfig = config
                await http.setAuthorizationRefresher {
                    let fresh = try await coordinator.accessToken(
                        for: serverID,
                        resource: resource,
                        httpConfig: httpConfig
                    )
                    return "Bearer \(fresh)"
                }
            }
            transport = http
        }

        let client = MCPClient(transport: transport)
        do {
            try await client.start()
            let tools = try await client.listTools()
            var registeredNames: [String] = []
            for tool in tools {
                let adapter = MCPToolAdapter(
                    serverName: serverSlug(record.displayName),
                    mcpTool: tool,
                    client: client
                )
                await toolRegistry.register(adapter)
                registeredNames.append(adapter.name)
            }
            entries[record.id] = Entry(client: client, adapterNames: registeredNames)
            status[record.id] = .ready(toolCount: tools.count)
        } catch {
            await client.shutdown()
            status[record.id] = .failed(Self.describe(error))
        }
    }

    /// Build the static (non-OAuth) Authorization header value for an
    /// HTTP server from its auth mode + the Keychain-stored token.
    /// Returns nil when the mode is `.none`, the token is missing, or
    /// no secret store is configured. For `.basic`, base64-encodes
    /// `email:token` (e.g. Atlassian personal API tokens).
    private func staticAuthorizationHeader(
        for id: MCPServerID,
        config: MCPTransportConfig.HTTPConfig
    ) async -> String? {
        guard config.authMode != .none, let secretStore else { return nil }
        let token = (try? await secretStore.secret(for: KeychainAccount.mcpStaticAuthToken(id))) ?? nil
        guard let token, !token.isEmpty else { return nil }
        switch config.authMode {
        case .none:
            return nil
        case .bearer:
            return "Bearer \(token)"
        case .basic:
            let email = config.basicAuthEmail ?? ""
            let pair = "\(email):\(token)"
            let encoded = Data(pair.utf8).base64EncodedString()
            return "Basic \(encoded)"
        }
    }

    /// Clean shutdown: stop the client, unregister its tools from the
    /// shared registry, flip status to `.disconnected`. Safe to call
    /// even if the server was never connected.
    func disconnect(_ id: MCPServerID) async {
        guard let entry = entries.removeValue(forKey: id) else {
            status[id] = .disconnected
            return
        }
        for name in entry.adapterNames {
            await toolRegistry.unregister(name: name)
        }
        await entry.client.shutdown()
        status[id] = .disconnected
    }

    /// Disconnect + reconnect in sequence. Used when the user edits the
    /// transport config of a connected server in Settings.
    func reconnect(_ record: MCPServerRecord) async {
        await disconnect(record.id)
        if record.enabled {
            await connect(record)
        }
    }

    /// MCPToolAdapter namespaces tool names as `mcp__<slug>__<tool>`. We
    /// derive the slug from the user's display name so users see something
    /// recognisable in tool-call rows ("mcp__filesystem__read_file"
    /// rather than a UUID). Lowercase, alphanumerics + underscore only.
    private func serverSlug(_ displayName: String) -> String {
        let lowered = displayName.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            if (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar.value == 0x5F { // _
                return Character(scalar)
            }
            return "_"
        }
        let collapsed = String(stripped).split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        return collapsed.isEmpty ? "server" : collapsed
    }

    private static func describe(_ error: Error) -> String {
        if let mcp = error as? MCPClientError {
            switch mcp {
            case .notInitialized: return "Not initialised"
            case .rpcError(let code, let message): return "RPC error \(code): \(message)"
            case .unexpectedResult: return "Unexpected result"
            case .transportClosed: return "Transport closed"
            }
        }
        return "\(error)"
    }
}

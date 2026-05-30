// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore

struct MCPTab: View {
    @Bindable var environment: AppEnvironment
    @State private var showAddSheet = false
    @State private var pendingDeletion: MCPServerID?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.top)
            Divider().padding(.top, 12)
            if environment.mcpServers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach($environment.mcpServers) { $record in
                            MCPServerCard(
                                record: $record,
                                environment: environment,
                                onDelete: { pendingDeletion = record.id }
                            )
                        }
                    }
                    .padding()
                }
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add server", systemImage: "plus")
                }
            }
            .padding()
        }
        .sheet(isPresented: $showAddSheet) {
            AddMCPServerSheet(environment: environment, isPresented: $showAddSheet)
        }
        .confirmDeletion(
            for: $pendingDeletion,
            title: { id in
                let name = environment.mcpServers.first(where: { $0.id == id })?.displayName ?? ""
                return "Delete server \"\(name)\"?"
            },
            message: { _ in
                Text("Its tools will no longer be available to any chat until you re-add it.")
            },
            onConfirm: { environment.removeMCPServer($0) }
        )
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model Context Protocol servers")
                    .font(.callout.bold())
                Text("Each enabled server's tools are advertised to every chat. Servers connect on first use this session.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No MCP servers yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Server card

private struct MCPServerCard: View {
    @Binding var record: MCPServerRecord
    @Bindable var environment: AppEnvironment
    let onDelete: () -> Void
    @State private var isExpanded: Bool = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                MCPServerForm(record: $record, environment: environment)
                    .padding(.top, 6)
            } label: {
                cardHeader
            }
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Text(record.displayName)
                .font(.headline)
            MCPStatusBadge(status: environment.mcpRegistry.status[record.id] ?? .disconnected)
            Spacer()
            Toggle("", isOn: Binding(
                get: { record.enabled },
                set: { environment.setMCPServerEnabled(record.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete server")
        }
        .contentShape(.rect)
    }
}

// MARK: - Server form (shared between Card body and AddSheet)

private struct MCPServerForm: View {
    @Binding var record: MCPServerRecord
    @Bindable var environment: AppEnvironment
    /// Cached "is there an access token in the Keychain for this
    /// server" lookup — drives the Sign in vs Re-authenticate label
    /// and the Sign out button's enabled state.
    @State fileprivate var hasAccessToken: Bool = false
    /// Human-readable reason the last sign-in attempt failed, shown
    /// inline under the buttons. nil when no error.
    @State fileprivate var signInError: String?
    /// True while the interactive OAuth flow is running.
    @State fileprivate var isSigningIn: Bool = false
    /// Draft static-auth token (bearer or basic API token). Persisted to
    /// the Keychain on commit, never bound directly to the config.
    @State fileprivate var staticTokenDraft: String = ""
    /// Whether a static token is already saved in the Keychain — drives
    /// the secure field's placeholder.
    @State fileprivate var hasStaticToken: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Display name") {
                TextField("Display name", text: $record.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            // Transport-type picker — switching variant resets the
            // payload so a stale stdio/http config doesn't linger when
            // the user changes their mind.
            Picker("Transport", selection: Binding(
                get: { record.transport.isStdio ? "stdio" : "http" },
                set: { newType in
                    if newType == "stdio", !record.transport.isStdio {
                        record.transport = .stdio(.init(command: ""))
                    } else if newType == "http", record.transport.isStdio {
                        record.transport = .http(.init(url: URL(string: "https://")!))
                    }
                }
            )) {
                Text("Stdio (subprocess)").tag("stdio")
                Text("HTTP").tag("http")
            }
            .pickerStyle(.segmented)

            switch record.transport {
            case .stdio:
                stdioFields
            case .http:
                httpFields
            }

            HStack {
                Button {
                    let snapshot = record
                    Task { await environment.mcpRegistry.connect(snapshot) }
                } label: {
                    Label("Test connection / refresh tools", systemImage: "antenna.radiowaves.left.and.right")
                }
                Spacer()
            }

            if case .failed(let message) = environment.mcpRegistry.status[record.id] ?? .disconnected {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: record) { _, new in
            environment.updateMCPServer(new)
        }
        .task(id: record.id) {
            await refreshSignInState()
        }
    }

    @ViewBuilder
    private var stdioFields: some View {
        if case .stdio(var config) = record.transport {
            LabeledContent("Command") {
                TextField("npx", text: Binding(
                    get: { config.command },
                    set: { newVal in
                        config.command = newVal
                        record.transport = .stdio(config)
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Arguments") {
                TextField("comma-separated", text: Binding(
                    get: { config.arguments.joined(separator: ", ") },
                    set: { newVal in
                        config.arguments = newVal
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        record.transport = .stdio(config)
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Environment") {
                // KEY=VALUE per line. Empty / malformed lines are dropped.
                TextEditor(text: Binding(
                    get: { config.environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") },
                    set: { newVal in
                        var env: [String: String] = [:]
                        for line in newVal.split(separator: "\n") {
                            if let eq = line.firstIndex(of: "=") {
                                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                                let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                                if !key.isEmpty { env[key] = value }
                            }
                        }
                        config.environment = env
                        record.transport = .stdio(config)
                    }
                ))
                .monospacedEditorBorder(minHeight: 60)
            }
            LabeledContent("Working directory") {
                TextField("optional", text: Binding(
                    get: { config.workingDirectory ?? "" },
                    set: { newVal in
                        config.workingDirectory = newVal.isEmpty ? nil : newVal
                        record.transport = .stdio(config)
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var httpFields: some View {
        if case .http(var config) = record.transport {
            LabeledContent("URL") {
                TextField("https://host/mcp", text: Binding(
                    get: { config.url.absoluteString },
                    set: { newVal in
                        if let url = URL(string: newVal), url.scheme != nil {
                            config.url = url
                            record.transport = .http(config)
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Toggle("Use OAuth", isOn: Binding(
                get: { config.useOAuth },
                set: { newVal in
                    config.useOAuth = newVal
                    record.transport = .http(config)
                }
            ))

            if config.useOAuth {
                oauthFields(config: config)
            } else {
                staticAuthFields(config: config)

                LabeledContent("Headers") {
                    // KEY=VALUE per line. Extra headers sent on every
                    // request. The Authorization header is managed by the
                    // Authentication picker above — don't set it here too.
                    TextEditor(text: Binding(
                        get: { config.headers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") },
                        set: { newVal in
                            var headers: [String: String] = [:]
                            for line in newVal.split(separator: "\n") {
                                if let eq = line.firstIndex(of: "=") {
                                    let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                                    let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                                    if !key.isEmpty { headers[key] = value }
                                }
                            }
                            config.headers = headers
                            record.transport = .http(config)
                        }
                    ))
                    .monospacedEditorBorder(minHeight: 60)
                }
            }
        }
    }

    @ViewBuilder
    private func staticAuthFields(config: MCPTransportConfig.HTTPConfig) -> some View {
        Picker("Authentication", selection: Binding(
            get: { config.authMode },
            set: { newMode in
                var c = config
                c.authMode = newMode
                record.transport = .http(c)
            }
        )) {
            Text("None").tag(MCPTransportConfig.HTTPAuthMode.none)
            Text("API token (Bearer)").tag(MCPTransportConfig.HTTPAuthMode.bearer)
            Text("API token (Basic, email + token)").tag(MCPTransportConfig.HTTPAuthMode.basic)
        }

        if config.authMode == .basic {
            LabeledContent("Email") {
                TextField("you@example.com", text: Binding(
                    get: { config.basicAuthEmail ?? "" },
                    set: { newVal in
                        var c = config
                        c.basicAuthEmail = newVal.isEmpty ? nil : newVal
                        record.transport = .http(c)
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }

        if config.authMode != .none {
            LabeledContent("API token") {
                HStack {
                    SecureField(hasStaticToken ? "•••••••• (saved in Keychain)" : "paste token",
                                text: $staticTokenDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let token = staticTokenDraft
                        Task {
                            await environment.setMCPStaticAuthToken(record.id, token: token)
                            staticTokenDraft = ""
                            await refreshSignInState()
                        }
                    }
                    .disabled(staticTokenDraft.isEmpty)
                    if hasStaticToken {
                        Button(role: .destructive) {
                            Task {
                                await environment.setMCPStaticAuthToken(record.id, token: nil)
                                await refreshSignInState()
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove saved token")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func oauthFields(config: MCPTransportConfig.HTTPConfig) -> some View {
        LabeledContent("Authorization server (optional)") {
            TextField("auto-discover from MCP server", text: Binding(
                get: { config.oauthAuthorizationServerURL?.absoluteString ?? "" },
                set: { newVal in
                    var c = config
                    c.oauthAuthorizationServerURL = URL(string: newVal)
                    record.transport = .http(c)
                }
            ))
            .textFieldStyle(.roundedBorder)
        }

        LabeledContent("Client ID (optional)") {
            TextField("blank to auto-register", text: Binding(
                get: { config.oauthClientID ?? "" },
                set: { newVal in
                    var c = config
                    c.oauthClientID = newVal.isEmpty ? nil : newVal
                    record.transport = .http(c)
                }
            ))
            .textFieldStyle(.roundedBorder)
        }

        LabeledContent("Scopes (optional)") {
            TextField("space-separated", text: Binding(
                get: { config.oauthScopes ?? "" },
                set: { newVal in
                    var c = config
                    c.oauthScopes = newVal.isEmpty ? nil : newVal
                    record.transport = .http(c)
                }
            ))
            .textFieldStyle(.roundedBorder)
        }

        HStack {
            Button {
                Task {
                    signInError = nil
                    isSigningIn = true
                    do {
                        try await environment.signInToMCPServer(record.id)
                    } catch {
                        signInError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    }
                    isSigningIn = false
                    await refreshSignInState()
                }
            } label: {
                Label(hasAccessToken ? "Re-authenticate" : "Sign in", systemImage: "key")
            }
            .disabled(isSigningIn)

            Button(role: .destructive) {
                Task {
                    await environment.signOutOfMCPServer(record.id)
                    await refreshSignInState()
                }
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(!hasAccessToken)

            if isSigningIn {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }

        if let signInError {
            Text(signInError)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

    }

    private func refreshSignInState() async {
        hasAccessToken = await environment.oauthCoordinator.hasStoredAccessToken(for: record.id)
        hasStaticToken = await environment.hasMCPStaticAuthToken(record.id)
    }
}

// MARK: - Add sheet

private struct AddMCPServerSheet: View {
    @Bindable var environment: AppEnvironment
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var transportType: String = "stdio"
    @State private var stdioCommand: String = ""
    @State private var stdioArguments: String = ""
    @State private var httpURL: String = "https://"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add MCP server").font(.title3.bold())
            TextField("Display name", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Transport", selection: $transportType) {
                Text("Stdio (subprocess)").tag("stdio")
                Text("HTTP").tag("http")
            }
            .pickerStyle(.segmented)

            if transportType == "stdio" {
                TextField("Command (e.g. npx)", text: $stdioCommand)
                    .textFieldStyle(.roundedBorder)
                TextField("Arguments (comma-separated)", text: $stdioArguments)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("URL (e.g. https://host/mcp)", text: $httpURL)
                    .textFieldStyle(.roundedBorder)
            }

            DialogActionButtons(
                confirmLabel: "Add",
                confirmDisabled: !addEnabled,
                onCancel: { isPresented = false },
                onConfirm: {
                    let transport: MCPTransportConfig
                    if transportType == "stdio" {
                        let args = stdioArguments
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        transport = .stdio(.init(command: stdioCommand, arguments: args))
                    } else {
                        guard let url = URL(string: httpURL), url.scheme != nil else { return }
                        transport = .http(.init(url: url))
                    }
                    _ = environment.addMCPServer(displayName: name, transport: transport)
                    isPresented = false
                }
            )
        }
        .padding(20)
        .frame(width: 480)
    }

    private var addEnabled: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return false }
        if transportType == "stdio" {
            return !stdioCommand.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if let url = URL(string: httpURL), url.scheme != nil { return true }
        return false
    }
}

// MARK: - Status badge

private struct MCPStatusBadge: View {
    let status: MCPRegistry.Status

    var body: some View {
        switch status {
        case .disconnected:
            Text("Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let count):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready · \(count) tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Helpers

private extension MCPTransportConfig {
    var isStdio: Bool {
        if case .stdio = self { return true }
        return false
    }
}

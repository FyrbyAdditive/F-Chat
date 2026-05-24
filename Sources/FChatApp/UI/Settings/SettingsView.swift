import SwiftUI
import FChatCore

struct SettingsView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        TabView {
            ProvidersTab(environment: environment)
                .tabItem { Label("Providers", systemImage: "antenna.radiowaves.left.and.right") }
            ToolsTab()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            MCPTab()
                .tabItem { Label("MCP", systemImage: "network") }
            CollectionsTab(environment: environment)
                .tabItem { Label("Collections", systemImage: "books.vertical") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 520)
    }
}

private struct ProvidersTab: View {
    @Bindable var environment: AppEnvironment
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            activeProviderHeader
                .padding(.horizontal)
                .padding(.top)
            Divider().padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach($environment.providerRecords) { $record in
                        ProviderCard(record: $record, environment: environment)
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add provider", systemImage: "plus")
                }
            }
            .padding()
        }
        .sheet(isPresented: $showAddSheet) {
            AddProviderSheet(environment: environment, isPresented: $showAddSheet)
        }
    }

    @ViewBuilder
    private var activeProviderHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Active provider")
                    .font(.callout.bold())
                Text("New chats use this provider and its default model. Each chat keeps its own setting; per-chat overrides live in the Inspector.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { environment.activeProviderID ?? environment.providerRecords.first?.id ?? ProviderID(rawValue: "") },
                set: { newID in environment.activeProviderID = newID }
            )) {
                ForEach(environment.providerRecords) { record in
                    Text(record.displayName).tag(record.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
            .disabled(environment.providerRecords.isEmpty)
        }
    }
}

private struct ProviderCard: View {
    @Binding var record: ProviderRecord
    @Bindable var environment: AppEnvironment
    @State private var baseURLText: String
    @State private var apiKeyDraft: String = ""
    @State private var apiKeyAlreadySaved: Bool = false
    @State private var saveMessage: String?

    init(record: Binding<ProviderRecord>, environment: AppEnvironment) {
        self._record = record
        self.environment = environment
        self._baseURLText = State(initialValue: record.wrappedValue.baseURL.absoluteString)
    }

    var body: some View {
        GroupBox(record.displayName) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(record.id.rawValue)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        environment.removeProvider(record.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove provider")
                }

                LabeledRow(label: "Display name") {
                    TextField("Display name", text: $record.displayName)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledRow(label: "Base URL") {
                    TextField("https://host/v1", text: $baseURLText, onCommit: commitBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitBaseURL)
                        .onChange(of: baseURLText) { _, _ in commitBaseURL() }
                }

                LabeledRow(label: "API key") {
                    HStack {
                        SecureField(apiKeyAlreadySaved ? "•••••••• (saved in Keychain)" : "Paste key — stored in Keychain",
                                    text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            saveAPIKey()
                        }
                        .disabled(apiKeyDraft.isEmpty)
                    }
                }

                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        Task { await environment.refreshModels(for: record) }
                    } label: {
                        Label("Test connection / fetch models", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    StatusBadge(status: environment.providerStatus[record.id] ?? .unknown)
                    Spacer()
                }

                let models = environment.detectedModels[record.id] ?? []
                if !models.isEmpty {
                    LabeledRow(label: "Default model") {
                        Picker("", selection: defaultModelBinding(models: models)) {
                            Text("— pick a default —").tag(String?.none)
                            ForEach(models) { info in
                                Text(info.displayName).tag(String?.some(info.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    Text("\(models.count) model\(models.count == 1 ? "" : "s") detected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
        .task(id: record.id) {
            apiKeyAlreadySaved = (try? await environment.secretStore.secret(for: KeychainAccount.providerAPIKey(record.id))) != nil
        }
    }

    private func commitBaseURL() {
        if let url = URL(string: baseURLText), url.scheme != nil {
            var updated = record
            updated.baseURL = url
            record = updated
        }
    }

    private func saveAPIKey() {
        let key = apiKeyDraft
        let id = record.id
        let store = environment.secretStore
        Task {
            do {
                try await store.setSecret(key, for: KeychainAccount.providerAPIKey(id))
                apiKeyDraft = ""
                apiKeyAlreadySaved = true
                saveMessage = "Saved to Keychain."
            } catch {
                saveMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    private func defaultModelBinding(models: [ModelInfo]) -> Binding<String?> {
        Binding(
            get: { record.defaultModel },
            set: { newValue in
                var updated = record
                updated.defaultModel = newValue
                record = updated
            }
        )
    }
}

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.callout)
            content()
        }
    }
}

private struct StatusBadge: View {
    let status: ProviderConnectionStatus
    var body: some View {
        switch status {
        case .unknown:
            Text("Not checked")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let count, let date):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(count) models · \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let msg, _):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }
}

private struct AddProviderSheet: View {
    @Bindable var environment: AppEnvironment
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var url: String = "https://"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add provider").font(.title3.bold())
            TextField("Display name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("https://host/v1", text: $url)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let parsed = URL(string: url), parsed.scheme != nil else {
                        error = "Enter a full URL including scheme."
                        return
                    }
                    _ = environment.addProvider(displayName: name, baseURL: parsed)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct ToolsTab: View {
    var body: some View {
        Form {
            Section("Built-in tools") {
                Text("Web search uses DuckDuckGo with no API key.")
                Text("Web fetch uses WKWebView + Mozilla Readability for clean extraction.")
                Text("RAG search queries your local collections.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MCPTab: View {
    var body: some View {
        Form {
            Section("MCP servers") {
                Text("Add stdio MCP servers here. HTTP transport coming in a follow-up.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CollectionsTab: View {
    @Bindable var environment: AppEnvironment
    var body: some View {
        Form {
            Section("Document collections") {
                Text("Drag files into a collection from the Collections sidebar entry.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
            Text("F-Chat").font(.title.bold())
            Text("Version \(FChat.version)")
                .foregroundStyle(.secondary)
            Text("Native macOS LLM chat client.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

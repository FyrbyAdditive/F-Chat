import SwiftUI
import FChatCore

struct SettingsView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        TabView {
            ProvidersTab(environment: environment)
                .tabItem { Label("Providers", systemImage: "antenna.radiowaves.left.and.right") }
            ToolsTab(environment: environment)
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
                } else if let current = record.defaultModel {
                    LabeledRow(label: "Default model") {
                        TextField("model-id", text: Binding(
                            get: { record.defaultModel ?? "" },
                            set: {
                                var updated = record
                                updated.defaultModel = $0.isEmpty ? nil : $0
                                record = updated
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    Text("Currently \(current). Click Test connection to discover models.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 4)

                SamplingSection(sampling: Binding(
                    get: { record.sampling },
                    set: {
                        var updated = record
                        updated.sampling = $0
                        record = updated
                    }
                ))

                Divider().padding(.vertical, 4)

                ContextSection(
                    context: Binding(
                        get: { record.context },
                        set: {
                            var updated = record
                            updated.context = $0
                            record = updated
                        }
                    ),
                    serverMax: environment.detectedModels[record.id]?
                        .first(where: { $0.id == record.defaultModel })?
                        .contextWindow
                )
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
    @Bindable var environment: AppEnvironment

    var body: some View {
        Form {
            Section {
                ToolToggleRow(
                    environment: environment,
                    name: "web_search",
                    title: "Web search",
                    description: "Search the public web via DuckDuckGo. No API key required."
                )
                ToolToggleRow(
                    environment: environment,
                    name: "web_fetch",
                    title: "Web fetch",
                    description: "Fetch a URL and extract main readable text using WKWebView + Mozilla Readability."
                )
                ToolToggleRow(
                    environment: environment,
                    name: "rag_search",
                    title: "RAG search",
                    description: "Query your local document collections."
                )
            } header: {
                Text("Built-in tools")
            } footer: {
                Text("Disabled tools are not advertised to the model and cannot be invoked.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ToolToggleRow: View {
    @Bindable var environment: AppEnvironment
    let name: String
    let title: String
    let description: String

    var body: some View {
        Toggle(isOn: Binding(
            get: { environment.enabledTools.contains(name) },
            set: { isOn in
                if isOn { environment.enabledTools.insert(name) }
                else { environment.enabledTools.remove(name) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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

private struct SamplingSection: View {
    @Binding var sampling: ProviderSamplingDefaults

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sampling defaults")
                .font(.callout.bold())
            Text("Used for every chat that talks to this provider.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            OptionalNumericRow(
                label: "Temperature",
                placeholder: "default",
                value: Binding(get: { sampling.temperature }, set: { sampling.temperature = $0 }),
                range: 0.0...2.0,
                step: 0.05,
                format: "%.2f"
            )
            OptionalNumericRow(
                label: "top_p",
                placeholder: "default",
                value: Binding(get: { sampling.topP }, set: { sampling.topP = $0 }),
                range: 0.0...1.0,
                step: 0.01,
                format: "%.2f"
            )
            OptionalIntRow(
                label: "Max output tokens",
                placeholder: "server default",
                value: Binding(get: { sampling.maxOutputTokens }, set: { sampling.maxOutputTokens = $0 }),
                defaultValue: 2048
            )

            Stepper(value: Binding(
                get: { sampling.maxToolIterations },
                set: { sampling.maxToolIterations = max(1, min($0, 32)) }
            ), in: 1...32) {
                HStack {
                    Text("Max tool iterations")
                    Spacer()
                    Text("\(sampling.maxToolIterations)").foregroundStyle(.secondary)
                }
            }

            Toggle("Parallel tool calls", isOn: Binding(
                get: { sampling.parallelToolCalls },
                set: { sampling.parallelToolCalls = $0 }
            ))
        }
    }
}

private struct ContextSection: View {
    @Binding var context: ProviderContextSettings
    let serverMax: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context window")
                .font(.callout.bold())
            Text("Controls auto-compaction. Older messages are summarized away when the projected request crosses the threshold.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Text("Hard cap (tokens)")
                    .frame(width: 160, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { context.hardCap != nil },
                    set: { enabled in
                        if enabled {
                            context.hardCap = context.hardCap ?? serverMax ?? 32_000
                        } else {
                            context.hardCap = nil
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            if let _ = context.hardCap {
                HStack {
                    TextField("budget", value: Binding(
                        get: { context.hardCap ?? 0 },
                        set: { context.hardCap = max(512, $0) }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                    if let serverMax {
                        Text("server max: \(serverMax.formatted())")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else if let serverMax {
                Text("Using server max: \(serverMax.formatted()) tokens.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Server max unknown — defaults to a safe 8,192 until you Test connection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Auto-compact at")
                    .frame(width: 160, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Slider(value: Binding(
                    get: { context.compactThreshold },
                    set: { context.compactThreshold = max(0.5, min(0.95, $0)) }
                ), in: 0.5...0.95, step: 0.05)
                Text("\(Int(context.compactThreshold * 100))%")
                    .font(.callout.monospaced())
                    .frame(minWidth: 50, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }

            Stepper(value: Binding(
                get: { context.recentKeepCount },
                set: { context.recentKeepCount = max(2, min(64, $0)) }
            ), in: 2...64) {
                HStack {
                    Text("Keep recent messages verbatim")
                    Spacer()
                    Text("\(context.recentKeepCount)").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct OptionalNumericRow: View {
    let label: String
    let placeholder: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Toggle("Override", isOn: Binding(
                    get: { value != nil },
                    set: { isOn in
                        if isOn {
                            if value == nil { value = (range.lowerBound + range.upperBound) / 2 }
                        } else {
                            value = nil
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            if let current = value {
                HStack {
                    Slider(value: Binding(
                        get: { current },
                        set: { value = $0 }
                    ), in: range, step: step)
                    Text(String(format: format, current))
                        .font(.callout.monospaced())
                        .frame(minWidth: 50, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(placeholder)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OptionalIntRow: View {
    let label: String
    let placeholder: String
    @Binding var value: Int?
    let defaultValue: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Toggle("Override", isOn: Binding(
                    get: { value != nil },
                    set: { isOn in
                        value = isOn ? (value ?? defaultValue) : nil
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
            if let current = value {
                Stepper(value: Binding(
                    get: { current },
                    set: { value = $0 }
                ), in: 1...1_000_000, step: 256) {
                    HStack {
                        Text("\(current)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                Text(placeholder)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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

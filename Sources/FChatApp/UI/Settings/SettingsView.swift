// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore
#if canImport(AppKit)
import AppKit
#endif

struct SettingsView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        TabView(selection: $environment.settingsTab) {
            ProvidersTab(environment: environment)
                .tabItem { Label("Providers", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(SettingsTab.providers)
            AgentsTab(environment: environment)
                .tabItem { Label("Agents", systemImage: "person.crop.circle") }
                .tag(SettingsTab.agents)
            ToolsTab(environment: environment)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.tools)
            SkillsTab(environment: environment)
                .tabItem { Label("Skills", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.skills)
            MCPTab(environment: environment)
                .tabItem { Label("MCP", systemImage: "network") }
                .tag(SettingsTab.mcp)
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding()
        // A stable minimum keeps the tabbed TabView from blowing out the
        // NavigationSplitView layout (an unbounded height lets tall tab content
        // disturb the sidebar). It still expands to fill a larger pane.
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
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
    /// Per-card expansion state. Defaults to collapsed so a list of many
    /// providers stays scannable; the user clicks the header to expand
    /// the one they want to edit. Not persisted across launches — most
    /// expansions are for a single edit session.
    @State private var isExpanded: Bool = false

    init(record: Binding<ProviderRecord>, environment: AppEnvironment) {
        self._record = record
        self.environment = environment
        self._baseURLText = State(initialValue: record.wrappedValue.baseURL.absoluteString)
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                providerForm
                    .padding(.top, 6)
            } label: {
                cardHeader
            }
        }
        .task(id: record.id) {
            apiKeyAlreadySaved = (try? await environment.secretStore.secret(for: KeychainAccount.providerAPIKey(record.id))) != nil
        }
    }

    /// Always-visible row inside the card: name, live status badge, and a
    /// trash button. Lets the user see provider state at a glance without
    /// expanding.
    private var cardHeader: some View {
        HStack(spacing: 8) {
            Text(record.displayName)
                .font(.headline)
            StatusBadge(status: environment.providerStatus[record.id] ?? .unknown)
            Spacer()
            Button(role: .destructive) {
                environment.removeProvider(record.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove provider")
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var providerForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.id.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Text("API type")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.apiKind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
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
                        // Pre-compute the placeholder as a LocalizedStringKey
                        // so the ternary doesn't collapse to a verbatim
                        // `String` and bypass localization.
                        let apiKeyPlaceholder: LocalizedStringKey = apiKeyAlreadySaved
                            ? "•••••••• (saved in Keychain)"
                            : "Paste key — stored in Keychain"
                        SecureField(apiKeyPlaceholder, text: $apiKeyDraft)
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

                Divider().padding(.vertical, 4)

                NetworkSection(timeout: Binding(
                    get: { record.requestTimeout },
                    set: {
                        var updated = record
                        updated.requestTimeout = $0
                        record = updated
                    }
                ))
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
                saveMessage = String(localized: "Saved to Keychain.")
            } catch {
                saveMessage = String(
                    localized: "Save failed: \(error.localizedDescription)"
                )
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
    let label: LocalizedStringKey
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
    @State private var apiKind: LLMAPIKind = .openAIResponses
    @State private var url: String = LLMAPIKind.openAIResponses.defaultBaseURL
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add provider").font(.title3.bold())
            TextField("Display name", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("API type", selection: $apiKind) {
                ForEach(LLMAPIKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: apiKind) { old, new in
                // Prefill the URL with the new kind's default endpoint, but
                // only when the user hasn't typed their own URL yet (the field
                // still holds the previous kind's default).
                if url.isEmpty || url == old.defaultBaseURL {
                    url = new.defaultBaseURL
                }
            }
            TextField("https://host/v1", text: $url)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            DialogActionButtons(
                confirmLabel: "Add",
                onCancel: { isPresented = false },
                onConfirm: {
                    guard let parsed = URL(string: url), parsed.scheme != nil else {
                        error = String(localized: "Enter a full URL including scheme.")
                        return
                    }
                    _ = environment.addProvider(displayName: name, baseURL: parsed, apiKind: apiKind)
                    isPresented = false
                }
            )
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
                    name: "current_time",
                    title: "Current time",
                    description: "Lets the model fetch the precise current time on demand. Off by default — the date is already in every message; enable this only when sub-day precision matters."
                )
                ToolToggleRow(
                    environment: environment,
                    name: "make_chart",
                    title: "Make chart",
                    description: "Lets the model render a bar, line, or pie chart inline in the chat. Off by default; enable when you want visual data displays."
                )
                ToolToggleRow(
                    environment: environment,
                    name: "contacts_search",
                    title: "Search Contacts",
                    description: "Lets the model look up your macOS Contacts (read-only — it never changes them). Off by default; enabling it asks macOS for Contacts permission.",
                    onEnable: { environment.requestContactsAccess() }
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
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    /// Optional side-effect fired when the toggle is switched ON (e.g. the
    /// Contacts tool requests the macOS permission). Nil for plain tools.
    var onEnable: (() -> Void)? = nil

    var body: some View {
        Toggle(isOn: Binding(
            get: { environment.enabledTools.contains(name) },
            set: { isOn in
                if isOn {
                    environment.enabledTools.insert(name)
                    onEnable?()
                } else {
                    environment.enabledTools.remove(name)
                }
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
                placeholder: "server default",
                value: Binding(get: { sampling.temperature }, set: { sampling.temperature = $0 }),
                range: 0.0...2.0,
                step: 0.05,
                format: "%.2f"
            )
            OptionalNumericRow(
                label: "top_p",
                placeholder: "server default",
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

private struct NetworkSection: View {
    @Binding var timeout: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Network")
                .font(.callout.bold())
            Text("Maximum idle time between data packets before a request fails. Resets on each byte received, so long active replies are fine — this only catches a stalled connection. Raise it if a slow backend times out mid-reply.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Stepper(value: Binding(
                get: { Int(timeout) },
                set: { timeout = TimeInterval(max(10, min(1800, $0))) }
            ), in: 10...1800, step: 30) {
                HStack {
                    Text("Request timeout (seconds)")
                    Spacer()
                    Text("\(Int(timeout))")
                        .foregroundStyle(.secondary)
                }
            }
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
            Text("Older messages are summarized away when the projected request would leave less than the reserve free for the reply.")
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

            Stepper(value: Binding(
                get: { context.outputReserve },
                set: { context.outputReserve = max(256, min(64_000, $0)) }
            ), in: 256...64_000, step: 512) {
                HStack {
                    Text("Reserve for reply (tokens)")
                    Spacer()
                    Text(context.outputReserve.formatted())
                        .foregroundStyle(.secondary)
                }
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
    let label: LocalizedStringKey
    let placeholder: LocalizedStringKey
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
    let label: LocalizedStringKey
    let placeholder: LocalizedStringKey
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
    @State private var showAcknowledgements = false

    var body: some View {
        VStack(spacing: 0) {
            // F-Chat logo + name/version/description, vertically centered in
            // the available space (equal spacers above and below).
            Spacer()
            VStack(spacing: 12) {
                Self.bundledImage(named: "AppLogo", fallbackSymbol: "sparkles")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    // macOS app icons use a squircle (continuous corner) at
                    // ~22% of the icon edge. 128 * 0.22 ≈ 28pt.
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                Text("F-Chat").font(.title.bold())
                Text("Version \(FChat.version)")
                    .foregroundStyle(.secondary)
                Text("Native macOS LLM chat client.")
                    .foregroundStyle(.secondary)

                // Licensing: F-Chat is GPLv3; third-party components are credited
                // in the acknowledgements sheet (bundled from Acknowledgements.md).
                // The source link satisfies GPLv3 §6 for the distributed binary —
                // recipients can get the corresponding source.
                VStack(spacing: 4) {
                    Text("Free software under the GNU GPL v3.0.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if let source = URL(string: "https://github.com/FyrbyAdditive/F-Chat") {
                            Link("Source code", destination: source)
                        }
                        Button("Open-source licenses") { showAcknowledgements = true }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)
                .padding(.top, 4)

                // Company wordmark just above the copyright line.
                Self.bundledImage(named: "FameLogo", fallbackSymbol: "building.2")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 128)
                    .accessibilityLabel("Fyrby Additive Manufacturing & Engineering")
                    .padding(.top, 20)
                Text("© 2026 Tim Ellis · Fyrby Additive Manufacturing & Engineering")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsSheet(isPresented: $showAcknowledgements)
        }
    }

    /// Load a PNG from the FChatApp SPM resource bundle as an NSImage.
    /// `Image(name:bundle:)` with a loose PNG path is unreliable in SPM
    /// resource bundles (it expects asset-catalog entries); going through
    /// NSImage with the resource URL always works. Falls back to an SF Symbol.
    private static func bundledImage(named name: String, fallbackSymbol: String) -> Image {
        #if canImport(AppKit)
        if let url = Bundle.module.url(forResource: name, withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            return Image(nsImage: nsImage)
        }
        #endif
        return Image(systemName: fallbackSymbol)
    }
}

/// Scrollable third-party license list, loaded from the bundled
/// `Acknowledgements.md` so the shipped binary carries its own attribution
/// (Apache-2.0/MIT require the notices travel with the distribution).
private struct AcknowledgementsSheet: View {
    @Binding var isPresented: Bool

    private var text: String {
        guard let url = Bundle.module.url(forResource: "Acknowledgements", withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8)
        else { return "Acknowledgements unavailable." }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open-source licenses").font(.title3.bold())
            ScrollView {
                Text(text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 360)
            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

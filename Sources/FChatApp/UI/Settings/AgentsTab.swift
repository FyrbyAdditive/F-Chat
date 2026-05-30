// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore

struct AgentsTab: View {
    @Bindable var environment: AppEnvironment
    @State private var showAddSheet = false
    @State private var pendingDeletion: AgentID?

    var body: some View {
        VStack(spacing: 0) {
            defaultAgentHeader
                .padding(.horizontal)
                .padding(.top)
            Divider().padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach($environment.agents) { $agent in
                        AgentCard(
                            agent: $agent,
                            environment: environment,
                            onDelete: { pendingDeletion = agent.id }
                        )
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
                    Label("Add agent", systemImage: "plus")
                }
            }
            .padding()
        }
        .sheet(isPresented: $showAddSheet) {
            AddAgentSheet(environment: environment, isPresented: $showAddSheet)
        }
        .confirmDeletion(
            for: $pendingDeletion,
            title: { id in
                let name = environment.agents.first(where: { $0.id == id })?.name ?? ""
                return "Delete agent \"\(name)\"?"
            },
            message: { id in
                let count = environment.chatCountUsingAgent(id)
                if count > 0 {
                    Text("\(count) chats will fall back to the Default agent.")
                } else {
                    Text("This agent isn't used by any chat.")
                }
            },
            onConfirm: { environment.deleteAgent($0) }
        )
    }

    @ViewBuilder
    private var defaultAgentHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default agent for new chats")
                    .font(.callout.bold())
                Text("This picks the agent any newly-created chat starts with. Individual chats can override in the Inspector.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { environment.defaultAgentForNewChats ?? .defaultAgent },
                set: { newID in
                    environment.defaultAgentForNewChats = (newID == .defaultAgent) ? nil : newID
                }
            )) {
                ForEach(environment.agents) { agent in
                    Text(agent.name).tag(agent.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
    }
}

private struct AgentCard: View {
    @Binding var agent: Agent
    @Bindable var environment: AppEnvironment
    let onDelete: () -> Void
    /// Per-card expansion state, in-memory only. Mirrors ProviderCard.
    @State private var isExpanded: Bool = false

    private var isDefault: Bool { agent.id == .defaultAgent }

    /// The localised built-in preamble, used as a read-only seed value
    /// when the Default agent hasn't been overridden, and as the target
    /// of "Revert to built-in".
    private var builtInPreamble: String {
        LocalizedSystemPrompt.builtInPreamble(for: environment.promptLanguage)
    }

    /// True when the Default agent is currently using the built-in
    /// preamble (i.e. `basePrompt == nil`). Used to disable Revert and
    /// to display the editor with the built-in text greyed in.
    private var isUsingBuiltIn: Bool {
        isDefault && (agent.basePrompt ?? "").isEmpty
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                agentForm
                    .padding(.top, 6)
            } label: {
                cardHeader
            }
        }
        .onChange(of: agent) { _, new in
            // Save-on-change via the existing scheduleSave debounce; we
            // only need to tell the environment the agent changed so
            // updatedAt bumps and persistence fires.
            environment.updateAgent(new)
        }
    }

    /// Always-visible row inside the card: name + per-card inline action
    /// (Revert for Default, trash for custom agents).
    private var cardHeader: some View {
        HStack(spacing: 8) {
            Text(agent.name)
                .font(.headline)
            Spacer()
            if isDefault {
                Button {
                    agent.basePrompt = nil
                } label: {
                    Label("Revert to built-in", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(isUsingBuiltIn)
                .help("Restore F-Chat's localised default preamble.")
            } else {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete agent")
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var agentForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isDefault {
                Text("Built-in agent — cannot be deleted or renamed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Name") {
                    TextField("Agent name", text: $agent.name)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("System prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isUsingBuiltIn {
                        Text("Showing F-Chat's built-in preamble. Edit to override.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                TextEditor(text: Binding(
                    get: { agent.basePrompt ?? builtInPreamble },
                    set: { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if isDefault {
                            // Equality to the built-in means "no override"
                            // — store nil so future locale changes still
                            // re-localise correctly.
                            if trimmed == builtInPreamble.trimmingCharacters(in: .whitespacesAndNewlines) {
                                agent.basePrompt = nil
                            } else {
                                agent.basePrompt = newValue.isEmpty ? nil : newValue
                            }
                        } else {
                            agent.basePrompt = newValue.isEmpty ? nil : newValue
                        }
                    }
                ))
                .monospacedEditorBorder()
                .foregroundStyle(isUsingBuiltIn ? .secondary : .primary)
            }
        }
    }
}

private struct AddAgentSheet: View {
    @Bindable var environment: AppEnvironment
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var basePrompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add agent").font(.title3.bold())
            TextField("Agent name", text: $name)
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $basePrompt)
                    .monospacedEditorBorder(minHeight: 160)
            }
            DialogActionButtons(
                confirmLabel: "Add",
                confirmDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onCancel: { isPresented = false },
                onConfirm: {
                    _ = environment.addAgent(name: name, basePrompt: basePrompt)
                    isPresented = false
                }
            )
        }
        .padding(20)
        .frame(width: 480, height: 380)
    }
}

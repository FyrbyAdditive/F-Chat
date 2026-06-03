// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FyxLocalCore

struct InspectorView: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var environment: AppEnvironment

    var body: some View {
        Form {
            Section("Conversation") {
                LabeledContent("Title") {
                    TextField(
                        "",
                        text: $viewModel.conversation.title,
                        prompt: Text("New chat")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                }
                // Agent picker folded into the Conversation section (was its own
                // section) to save the extra header + spacing.
                LabeledContent("Agent") {
                    Picker("Agent", selection: Binding(
                        get: {
                            // nil → global default → Default agent.
                            viewModel.conversation.settings.agentID
                                ?? environment.defaultAgentForNewChats
                                ?? .defaultAgent
                        },
                        set: { newID in
                            viewModel.conversation.settings.agentID = newID
                        }
                    )) {
                        ForEach(environment.agents) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                LabeledContent("Created") {
                    Text(viewModel.conversation.createdAt, format: .dateTime)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Updated") {
                    Text(viewModel.conversation.updatedAt, format: .dateTime)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Messages") {
                    Text("\(viewModel.conversation.messages.count)")
                        .foregroundStyle(.secondary)
                }
            }

            CollectionsAttachSection(viewModel: viewModel, environment: environment)

            SkillsAttachSection(viewModel: viewModel, environment: environment)
        }
        .formStyle(.grouped)
    }
}

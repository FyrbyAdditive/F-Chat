// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore

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

            AgentPickerSection(viewModel: viewModel, environment: environment)

            CollectionsAttachSection(viewModel: viewModel, environment: environment)

            SkillsAttachSection(viewModel: viewModel, environment: environment)
        }
        .formStyle(.grouped)
    }
}

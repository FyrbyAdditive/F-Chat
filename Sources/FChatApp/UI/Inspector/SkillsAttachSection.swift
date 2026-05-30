// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore

/// Inspector section: list every skill in the global library with a toggle
/// bound to the active chat's `enabledSkills`. Toggling on adds the skill's
/// name + description to this chat's system prompt and makes the `run_code`
/// tool available, scoped to the enabled skills. Skills marked "apply to every
/// chat" show as on and locked (they're always active).
struct SkillsAttachSection: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var environment: AppEnvironment

    var body: some View {
        Section("Skills") {
            if environment.skills.isEmpty {
                Text("No skills yet. Add one in Settings → Skills.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Skills available in this chat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(environment.skills) { skill in
                    if skill.enabledByDefault {
                        // Always-on for every chat; shown locked so the user
                        // sees it's active without being able to turn it off
                        // here (that's a global setting in Settings → Skills).
                        Toggle(skill.name, isOn: .constant(true))
                            .disabled(true)
                            .help("Applies to every chat (change in Settings → Skills).")
                    } else {
                        Toggle(skill.name, isOn: toggleBinding(for: skill.id))
                    }
                }
            }
        }
    }

    private func toggleBinding(for id: SkillID) -> Binding<Bool> {
        Binding(
            get: { viewModel.conversation.settings.enabledSkills.contains(id) },
            set: { isOn in
                var s = viewModel.conversation.settings
                if isOn { s.enabledSkills.insert(id) }
                else { s.enabledSkills.remove(id) }
                viewModel.conversation.settings = s
            }
        )
    }
}

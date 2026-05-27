import SwiftUI
import FChatCore

struct AgentPickerSection: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var environment: AppEnvironment

    var body: some View {
        Section("Agent") {
            Picker("Agent", selection: Binding(
                get: {
                    // nil → fall back to global default → fall back to Default agent.
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

            Text("Set the default for new chats in Settings → Agents.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

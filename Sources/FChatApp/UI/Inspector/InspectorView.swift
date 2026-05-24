import SwiftUI
import FChatCore

struct InspectorView: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var environment: AppEnvironment

    var body: some View {
        Form {
            Section("Conversation") {
                LabeledContent("Title") {
                    Text(viewModel.conversation.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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

            Section("Active provider") {
                if let record = environment.currentProvider() {
                    LabeledContent("Provider") {
                        Text(record.displayName).foregroundStyle(.secondary)
                    }
                    LabeledContent("Model") {
                        Text(record.defaultModel ?? "—").foregroundStyle(.secondary)
                    }
                    Text("Configure model and sampling in Settings → Providers.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No provider configured. Open Settings → Providers.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

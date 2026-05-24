import SwiftUI
import FChatCore

struct InspectorView: View {
    @Bindable var viewModel: ChatViewModel

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
        }
        .formStyle(.grouped)
    }
}

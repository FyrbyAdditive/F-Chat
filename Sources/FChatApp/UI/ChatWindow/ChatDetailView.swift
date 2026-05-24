import SwiftUI
import FChatCore

struct ChatDetailView: View {
    @Bindable var environment: AppEnvironment
    let conversationID: ConversationID
    @State private var viewModel: ChatViewModel?
    @State private var showInspector = true

    var body: some View {
        Group {
            if let viewModel {
                VStack(spacing: 0) {
                    TranscriptView(
                        conversation: viewModel.conversation,
                        failureForMessageID: viewModel.failedUserMessageID,
                        failureMessage: viewModel.lastError,
                        onRetry: { viewModel.retryLastFailedMessage() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ComposerView(viewModel: viewModel)
                }
                .inspector(isPresented: $showInspector) {
                    InspectorView(viewModel: viewModel)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
                .navigationTitle(viewModel.conversation.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showInspector.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: conversationID) {
            if let conversation = environment.conversation(conversationID) {
                viewModel = ChatViewModel(conversation: conversation, environment: environment)
            }
        }
    }
}

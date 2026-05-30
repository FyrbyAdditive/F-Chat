import SwiftUI
import FChatCore

struct ChatDetailView: View {
    @Bindable var environment: AppEnvironment
    let conversationID: ConversationID
    @State private var showInspector = true

    var body: some View {
        // View models live in the environment so an in-flight stream
        // survives sidebar navigation. Re-rendering this view simply
        // re-binds against the existing VM if there is one.
        let viewModel = environment.viewModel(for: conversationID)
        Group {
            if let viewModel {
                VStack(spacing: 0) {
                    TranscriptView(
                        conversation: viewModel.conversation,
                        failureForMessageID: viewModel.failedUserMessageID,
                        failureMessage: viewModel.lastError,
                        onRetry: { viewModel.retryLastFailedMessage() },
                        streamingMessageID: viewModel.isStreaming
                            ? viewModel.conversation.messages.last?.id
                            : nil
                    )
                    // Force SwiftUI to treat each chat as a fresh subtree
                    // so the ScrollView's preserved scroll offset doesn't
                    // bleed across chat switches.
                    .id(conversationID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ComposerView(viewModel: viewModel)
                }
                .inspector(isPresented: $showInspector) {
                    InspectorView(viewModel: viewModel, environment: environment)
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
                // No view model means this conversation no longer exists (e.g.
                // it was just deleted and the detail pane is rendering a stale
                // id for a frame). Show the empty placeholder — NOT a spinner,
                // which misleadingly reads as "loading".
                EmptyPlaceholderView()
            }
        }
        // Sidebar rename writes directly into environment.conversations[i],
        // which doesn't propagate back into the active view model's copy.
        // When the environment's title for this chat changes externally and
        // diverges from what the view model currently shows, pull it in so
        // the inspector + nav-title stay in sync.
        .onChange(of: environment.conversation(conversationID)?.title) { _, newTitle in
            guard let newTitle, let vm = environment.viewModel(for: conversationID) else { return }
            if vm.conversation.title != newTitle {
                vm.conversation.title = newTitle
            }
        }
    }
}

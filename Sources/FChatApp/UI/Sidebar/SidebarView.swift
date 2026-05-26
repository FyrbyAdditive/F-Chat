import SwiftUI
import FChatCore

struct SidebarView: View {
    @Bindable var environment: AppEnvironment
    @State private var pendingDeletion: ConversationID?
    /// Id of the conversation currently being renamed in-place. nil = no
    /// active rename. The matching row swaps its title `Text` for a focused
    /// `TextField` bound to `renameDraft`.
    @State private var renamingID: ConversationID?
    @State private var renameDraft: String = ""
    @FocusState private var renameFieldFocus: ConversationID?

    var body: some View {
        List(selection: $environment.sidebarSelection) {
            Section {
                ForEach(environment.conversations) { conversation in
                    conversationRow(conversation)
                }
            } header: {
                HStack {
                    Text("Conversations")
                    Spacer()
                    if !environment.conversations.isEmpty {
                        Text("\(environment.conversations.count)")
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 6)
                    }
                }
            }

            Section {
                NavigationLink(value: SidebarSelection.collections) {
                    Label("Collections", systemImage: "books.vertical")
                }
                NavigationLink(value: SidebarSelection.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        // Return on a selected row enters rename mode, mirroring Finder.
        // Returns .ignored if no row is selected or one is already being
        // renamed (so the inline TextField's own submit still works).
        .onKeyPress(.return) {
            guard renamingID == nil,
                  case .conversation(let id) = environment.sidebarSelection,
                  let conversation = environment.conversations.first(where: { $0.id == id })
            else { return .ignored }
            beginRename(conversation)
            return .handled
        }
        .navigationTitle("F-Chat")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    environment.newConversation(title: "New chat")
                } label: {
                    Label("New chat", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeletion {
                    environment.deleteConversation(id)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("This conversation will be removed permanently. This cannot be undone.")
        }
    }

    @ViewBuilder
    private func conversationRow(_ conversation: Conversation) -> some View {
        NavigationLink(value: SidebarSelection.conversation(conversation.id)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if renamingID == conversation.id {
                        TextField("Chat name", text: $renameDraft)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .focused($renameFieldFocus, equals: conversation.id)
                            .onSubmit { commitRename() }
                            .onExitCommand { cancelRename() }
                            .onChange(of: renameFieldFocus) { _, newFocus in
                                // Focus moved away from this field — commit
                                // whatever was typed. Guard against the
                                // commit-then-clear feedback loop.
                                if newFocus != conversation.id && renamingID == conversation.id {
                                    commitRename()
                                }
                            }
                    } else {
                        Text(conversation.title)
                            .lineLimit(1)
                            .font(.body)
                    }
                    Spacer(minLength: 0)
                    // Tiny indicator when a background stream is still
                    // running for this chat. Only chats the user has
                    // visited this session have a cached view model;
                    // never-visited chats never have an in-flight stream.
                    if environment.chatViewModels[conversation.id]?.isStreaming == true {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                pendingDeletion = conversation.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                environment.sidebarSelection = .conversation(conversation.id)
                environment.selectedConversationID = conversation.id
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            Button {
                beginRename(conversation)
            } label: {
                Label("Rename\u{2026}", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                pendingDeletion = conversation.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func beginRename(_ conversation: Conversation) {
        renameDraft = conversation.title
        renamingID = conversation.id
        // Defer focus until the TextField actually mounts on the next runloop
        // tick; setting both in the same frame races with view creation.
        Task { @MainActor in
            renameFieldFocus = conversation.id
        }
    }

    private func commitRename() {
        guard let id = renamingID,
              let index = environment.conversations.firstIndex(where: { $0.id == id })
        else {
            renamingID = nil
            return
        }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != environment.conversations[index].title {
            environment.conversations[index].title = trimmed
        }
        renamingID = nil
        renameDraft = ""
    }

    private func cancelRename() {
        renamingID = nil
        renameDraft = ""
    }

    private var confirmationTitle: String {
        guard let id = pendingDeletion,
              let convo = environment.conversations.first(where: { $0.id == id }) else {
            return "Delete conversation?"
        }
        return "Delete \"\(convo.title)\"?"
    }
}

import SwiftUI
import FChatCore

struct SidebarView: View {
    @Bindable var environment: AppEnvironment
    @State private var pendingDeletion: ConversationID?

    var body: some View {
        List(selection: $environment.sidebarSelection) {
            Section {
                ForEach(environment.conversations) { conversation in
                    NavigationLink(value: SidebarSelection.conversation(conversation.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .lineLimit(1)
                                .font(.body)
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
                        Divider()
                        Button(role: .destructive) {
                            pendingDeletion = conversation.id
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Conversations")
                    Spacer()
                    if !environment.conversations.isEmpty {
                        Text("\(environment.conversations.count)")
                            .foregroundStyle(.secondary)
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

    private var confirmationTitle: String {
        guard let id = pendingDeletion,
              let convo = environment.conversations.first(where: { $0.id == id }) else {
            return "Delete conversation?"
        }
        return "Delete \"\(convo.title)\"?"
    }
}

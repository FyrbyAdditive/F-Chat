// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore
import FChatRAG

/// Inspector section: list every collection with a toggle bound to the
/// active chat's `attachedCollections`. Toggling on means the next
/// `rag_search` invocation will be allowed to query that collection.
struct CollectionsAttachSection: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var environment: AppEnvironment
    @State private var collections: [RAGCollection] = []
    @State private var refreshTrigger = 0

    var body: some View {
        Section("Collections") {
            if collections.isEmpty {
                Text("No collections yet. Create one in the Collections pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Documents available in this chat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(collections) { collection in
                    Toggle(collection.name, isOn: toggleBinding(for: collection.id))
                }
            }
        }
        .task(id: refreshTrigger) { await refresh() }
        .onAppear { refreshTrigger += 1 }
    }

    private func toggleBinding(for id: CollectionID) -> Binding<Bool> {
        Binding(
            get: { viewModel.conversation.settings.attachedCollections.contains(id) },
            set: { isOn in
                var s = viewModel.conversation.settings
                if isOn { s.attachedCollections.insert(id) }
                else { s.attachedCollections.remove(id) }
                viewModel.conversation.settings = s
            }
        )
    }

    private func refresh() async {
        let all = await environment.collectionStore.listCollections()
        await MainActor.run { collections = all }
    }
}

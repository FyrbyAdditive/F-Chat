// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore

/// Import wizard: shows the chats found in an export and lets the user
/// cherry-pick which to import (a Claude export is the user's whole history).
/// All chats are selected by default; a search field filters by title, and
/// Select all / none act on the *visible* (filtered) rows.
struct ImportChatsSheet: View {
    @Bindable var environment: AppEnvironment
    let preview: ChatImportPreview
    @Binding var isPresented: Bool
    /// Called with the committed summary so the sidebar can show its alert.
    let onCommit: (ChatImportSummary) -> Void

    @State private var selected: Set<Int>
    @State private var search: String = ""

    init(environment: AppEnvironment, preview: ChatImportPreview, isPresented: Binding<Bool>, onCommit: @escaping (ChatImportSummary) -> Void) {
        self.environment = environment
        self.preview = preview
        self._isPresented = isPresented
        self.onCommit = onCommit
        // Default: everything selected.
        _selected = State(initialValue: Set(preview.items.map(\.index)))
    }

    private var filtered: [ChatImportPreview.Item] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return preview.items }
        return preview.items.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from \(preview.format.rawValue)").font(.title3.bold())
            Text("\(preview.items.count) conversation(s) found. Choose which to import.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles", text: $search)
                    .textFieldStyle(.plain)
                Spacer()
                Button("Select all") { selectAllVisible() }
                    .buttonStyle(.link)
                Button("Select none") { deselectAllVisible() }
                    .buttonStyle(.link)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))

            List {
                ForEach(filtered) { item in
                    row(item)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 280)

            HStack {
                Text("\(selected.count) of \(preview.items.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    let summary = environment.commitImport(preview, selecting: selected)
                    isPresented = false
                    onCommit(summary)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    @ViewBuilder
    private func row(_ item: ChatImportPreview.Item) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(item.index) },
            set: { isOn in
                if isOn { selected.insert(item.index) } else { selected.remove(item.index) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text("\(item.messageCount) messages · \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func selectAllVisible() {
        for item in filtered { selected.insert(item.index) }
    }
    private func deselectAllVisible() {
        for item in filtered { selected.remove(item.index) }
    }
}

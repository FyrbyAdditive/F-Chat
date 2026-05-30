// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore

/// Export wizard: lets the user cherry-pick which conversations to export and in
/// which format. Mirrors `ImportChatsSheet` (all selected by default, search,
/// select-all/none on visible rows) and adds a format picker. The Export button
/// builds the bytes and hands them back via `onExport`; the sidebar then drives
/// `.fileExporter` to write the file.
struct ExportChatsSheet: View {
    @Bindable var environment: AppEnvironment
    let preview: ChatExportPreview
    @Binding var isPresented: Bool
    /// Called with the built bundle once the user confirms, so the sidebar can
    /// present the save panel.
    let onExport: (ChatExportBundle) -> Void
    /// Called with a user-facing error string if the build fails.
    let onError: (String) -> Void

    @State private var selected: Set<Int>
    @State private var search: String = ""
    @State private var format: ChatExportFormat = .markdown

    init(environment: AppEnvironment, preview: ChatExportPreview, isPresented: Binding<Bool>,
         onExport: @escaping (ChatExportBundle) -> Void, onError: @escaping (String) -> Void) {
        self.environment = environment
        self.preview = preview
        self._isPresented = isPresented
        self.onExport = onExport
        self.onError = onError
        // Default: everything selected.
        _selected = State(initialValue: Set(preview.items.map(\.index)))
    }

    private var filtered: [ChatExportPreview.Item] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return preview.items }
        return preview.items.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export chats").font(.title3.bold())
            Text("Choose which conversations to export and the format.")
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
            .frame(minHeight: 260)

            Picker("Format", selection: $format) {
                ForEach(ChatExportFormat.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("\(selected.count) of \(preview.items.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { performExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
    }

    @ViewBuilder
    private func row(_ item: ChatExportPreview.Item) -> some View {
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

    private func performExport() {
        let ids = preview.items.filter { selected.contains($0.index) }.map(\.id)
        do {
            let bundle = try environment.buildExport(conversationIDs: ids, format: format)
            isPresented = false
            onExport(bundle)
        } catch {
            isPresented = false
            onError((error as? CustomStringConvertible)?.description ?? error.localizedDescription)
        }
    }

    private func selectAllVisible() {
        for item in filtered { selected.insert(item.index) }
    }
    private func deselectAllVisible() {
        for item in filtered { selected.remove(item.index) }
    }
}

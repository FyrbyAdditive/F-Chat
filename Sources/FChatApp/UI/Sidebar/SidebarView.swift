// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore
#if canImport(AppKit)
import AppKit
#endif

struct SidebarView: View {
    @Bindable var environment: AppEnvironment
    @State private var pendingDeletion: ConversationID?
    /// Id of the conversation currently being renamed in-place. nil = no
    /// active rename. The matching row swaps its title `Text` for a focused
    /// `TextField` bound to `renameDraft`.
    @State private var renamingID: ConversationID?
    @State private var renameDraft: String = ""
    @FocusState private var renameFieldFocus: ConversationID?
    /// Chat-import (ChatGPT/Claude) flow: file picker → parsed preview shown in
    /// the wizard sheet → committed-summary / error alert.
    @State private var showChatImporter = false
    @State private var importPreview: ChatImportPreview?
    @State private var importResult: ChatImportSummary?
    @State private var importError: String?
    /// Chat-export flow: wizard (cherry-pick + format) builds a bundle →
    /// `.fileExporter` save panel writes it. Single-chat export skips the wizard.
    @State private var exportPreview: ChatExportPreview?
    @State private var pendingExportBundle: ChatExportBundle?
    @State private var showExportSavePanel = false
    @State private var exportError: String?

    var body: some View {
        // The conversations list scrolls on its own; Collections + Settings are
        // pinned to the bottom via a safe-area inset so they never scroll out
        // of view no matter how many chats there are.
        List(selection: $environment.sidebarSelection) {
            Section {
                ForEach(environment.conversations) { conversation in
                    conversationRow(conversation)
                }
                // Drag-to-reorder. Mutating environment.conversations
                // in place takes the new order through the existing
                // scheduleSave debounce; no schema change required.
                .onMove { indices, newOffset in
                    environment.conversations.move(fromOffsets: indices, toOffset: newOffset)
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
        }
        // Keep the List's own (darker) sidebar background; the pinned footer
        // paints that exact colour itself so it matches the chat list above.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
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
                    showChatImporter = true
                } label: {
                    Label("Import chats", systemImage: "square.and.arrow.down")
                }
                .help("Import conversations exported from ChatGPT or Claude")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportPreview = environment.exportPreview()
                } label: {
                    Label("Export chats", systemImage: "square.and.arrow.up")
                }
                .help("Export conversations to Markdown, JSON, Word, or text")
                .disabled(environment.conversations.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    environment.newConversation(title: "New chat")
                } label: {
                    Label("New chat", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
        // File ▸ Import Chats… routes here so the menu and the toolbar button
        // drive the one picker + wizard the sidebar owns.
        .onChange(of: environment.importChatsRequests) { _, _ in
            showChatImporter = true
        }
        .fileImporter(
            isPresented: $showChatImporter,
            allowedContentTypes: [.json, .zip],
            allowsMultipleSelection: false
        ) { result in
            handleChatImport(result)
        }
        .sheet(isPresented: Binding(
            get: { importPreview != nil },
            set: { if !$0 { importPreview = nil } }
        )) {
            if let preview = importPreview {
                ImportChatsSheet(
                    environment: environment,
                    preview: preview,
                    isPresented: Binding(
                        get: { importPreview != nil },
                        set: { if !$0 { importPreview = nil } }
                    ),
                    onCommit: { importResult = $0 }
                )
            }
        }
        .alert("Import chats", isPresented: importAlertPresented) {
            Button("OK", role: .cancel) { importResult = nil; importError = nil }
        } message: {
            if let importError {
                Text(importError)
            } else if let importResult {
                Text(importSummaryMessage(importResult))
            }
        }
        // Export — toolbar button and File ▸ Export Chats… both open the wizard;
        // the row context menu requests a single-chat export (no wizard).
        .onChange(of: environment.exportChatsRequests) { _, _ in
            exportPreview = environment.exportPreview()
        }
        .sheet(isPresented: Binding(
            get: { exportPreview != nil },
            set: { if !$0 { exportPreview = nil } }
        )) {
            if let preview = exportPreview {
                ExportChatsSheet(
                    environment: environment,
                    preview: preview,
                    isPresented: Binding(
                        get: { exportPreview != nil },
                        set: { if !$0 { exportPreview = nil } }
                    ),
                    onExport: { bundle in
                        pendingExportBundle = bundle
                        showExportSavePanel = true
                    },
                    onError: { exportError = $0 }
                )
            }
        }
        // Save via NSSavePanel rather than .fileExporter: the format is already
        // chosen (in the wizard or the context-menu submenu), so the panel must
        // NOT offer a different list of file types. NSSavePanel with a single
        // allowedContentType shows exactly the chosen format and nothing else.
        .onChange(of: showExportSavePanel) { _, present in
            guard present, let bundle = pendingExportBundle else { return }
            showExportSavePanel = false
            presentSavePanel(for: bundle)
        }
        .alert("Export chats", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            if let exportError { Text(exportError) }
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

    /// Collections + Settings, pinned at the bottom of the sidebar. A small
    /// non-scrolling `List` bound to the SAME `sidebarSelection` as the main
    /// list, so it keeps the native sidebar row look and the selection
    /// highlight tracks whichever pane is active (the chat list and this footer
    /// share the one selection binding).
    @ViewBuilder
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            // Hairline separator from the scrolling chat list above.
            Divider()
            VStack(spacing: 2) {
                footerRow(.collections, title: "Collections", icon: "books.vertical")
                footerRow(.settings, title: "Settings", icon: "gearshape")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        // Paint the footer with the chat list's own rendered colour so it
        // reads as the same surface (the standalone `.sidebar` material blends
        // lighter inside the window, so we match the measured list colour
        // directly, adapting to light/dark).
        .background(Color.sidebarListBackground)
    }

    /// One pinned footer row, styled to read like a native sidebar row: a
    /// selection-tinted rounded capsule behind the label when its pane is
    /// active. Sits directly on the sidebar material (no box/border) so it
    /// blends in rather than looking like a detached widget.
    @ViewBuilder
    private func footerRow(_ selection: SidebarSelection, title: LocalizedStringKey, icon: String) -> some View {
        let isSelected = environment.sidebarSelection == selection
        Button {
            environment.sidebarSelection = selection
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
                )
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .contentShape(.rect)
    }
        .buttonStyle(.plain)
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
            Menu {
                ForEach(ChatExportFormat.allCases) { format in
                    Button(format.displayName) {
                        handleSingleChatExport(conversation.id, format: format)
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                pendingDeletion = conversation.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Chat import

    private var importAlertPresented: Binding<Bool> {
        Binding(
            get: { importResult != nil || importError != nil },
            set: { if !$0 { importResult = nil; importError = nil } }
        )
    }

    private func handleChatImport(_ result: Result<[URL], Error>) {
        importResult = nil
        importError = nil
        importPreview = nil
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Phase 1: parse to a preview, then present the selection wizard.
            importPreview = try environment.prepareImport(from: url)
        } catch {
            importError = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        }
    }

    /// Build a single conversation's export in the chosen format and present the
    /// save panel (defaulting to the sanitised chat title).
    private func handleSingleChatExport(_ id: ConversationID, format: ChatExportFormat) {
        do {
            pendingExportBundle = try environment.buildExport(single: id, format: format)
            showExportSavePanel = true
        } catch {
            exportError = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        }
    }

    /// Write an already-built bundle via an NSSavePanel locked to the bundle's
    /// own content type — the format was chosen upstream, so the panel offers no
    /// other file types.
    private func presentSavePanel(for bundle: ChatExportBundle) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = bundle.suggestedFilename
        panel.allowedContentTypes = [bundle.contentType]
        // The filename already carries the right extension; don't let the panel
        // hide or second-guess it.
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.showsTagField = false
        let data = bundle.data
        pendingExportBundle = nil
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func importSummaryMessage(_ s: ChatImportSummary) -> String {
        var msg = String(
            localized: "Imported \(s.conversationCount) conversation(s) (\(s.messageCount) messages) from \(s.format.rawValue)."
        )
        if !s.warnings.isEmpty {
            msg += "\n\n" + s.warnings.joined(separator: "\n")
        }
        return msg
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

private extension Color {
    /// The chat list's rendered sidebar background colour, matched directly so
    /// the pinned footer is the same surface. The SwiftUI sidebar `List` blends
    /// its material *behind the window* (against the desktop), so a standalone
    /// material layer comes out a different (lighter) grey — we match the
    /// measured colour instead, adapting to light/dark.
    static let sidebarListBackground = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 22/255, green: 24/255, blue: 26/255, alpha: 1)
            : NSColor(srgbRed: 246/255, green: 246/255, blue: 247/255, alpha: 1)
    })
}


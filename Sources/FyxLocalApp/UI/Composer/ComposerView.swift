// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import UniformTypeIdentifiers
import FyxLocalCore

struct ComposerView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var focused: Bool
    @State private var showingImporter = false
    @State private var attachError: String?

    var body: some View {
        VStack(spacing: 6) {
            if let error = viewModel.lastError, viewModel.failedUserMessageID == nil {
                // Composer-level errors are reserved for things that aren't
                // attached to a specific message — like "no provider
                // configured" or oversized-input rejection. Per-message
                // failures (network, summarizer) attach to the failed
                // user message and show a Retry button there instead.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.errorFill, in: RoundedRectangle(cornerRadius: 8))
            }
            if viewModel.isCompacting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Compacting context…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            if let attachError {
                Label(attachError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            if !viewModel.draftAttachments.isEmpty {
                attachmentChips
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Attach button: images (when the model accepts them) + text files.
                Button {
                    attachError = nil
                    showingImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Attach an image or text file")

                // TextField(axis: .vertical) starts at one line and grows up
                // to lineLimit before scrolling, unlike TextEditor which is
                // multi-line from the start. Bare Return submits; Shift+Return
                // inserts a literal newline.
                TextField("Message", text: $viewModel.draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.composerCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.composerCornerRadius)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .onSubmit(submitIfReady)

                Button(action: submitIfReady) {
                    Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(DesignTokens.accent.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!viewModel.isStreaming && !viewModel.canSend)
            }
            composerToolbar
        }
        .padding(DesignTokens.panelPadding)
        .onAppear { focused = true }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importerContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handlePicked(result)
        }
        // Drag-and-drop files onto the composer.
        .dropDestination(for: URL.self) { urls, _ in
            ingest(urls)
            return true
        }
    }

    /// Chips for pending attachments, each removable.
    @ViewBuilder
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.draftAttachments) { att in
                    HStack(spacing: 4) {
                        Image(systemName: att.isImage ? "photo" : "doc.text")
                            .font(.caption)
                        Text(att.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            viewModel.removeAttachment(att)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// File types the picker offers: text always; images only when supported.
    private var importerContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .sourceCode, .json, .commaSeparatedText, .text]
        if viewModel.activeModelAcceptsImages { types.append(.image) }
        return types
    }

    private func handlePicked(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): ingest(urls)
        case .failure(let error): attachError = error.localizedDescription
        }
    }

    /// Route each file through the view model, surfacing the first error.
    private func ingest(_ urls: [URL]) {
        for url in urls {
            // Security-scoped access for sandbox-picked files; harmless otherwise.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let err = viewModel.addAttachment(from: url) {
                attachError = err
            }
        }
    }

    @ViewBuilder
    private var composerToolbar: some View {
        HStack(spacing: 6) {
            ReasoningMenu(
                current: viewModel.conversation.reasoningEffort,
                onSelect: { effort in
                    viewModel.conversation.reasoningEffort = effort
                }
            )
            TokenMeter(
                projection: viewModel.projection,
                budget: viewModel.budget,
                isCompacting: viewModel.isCompacting,
                onCompactNow: { viewModel.compactNow() }
            )
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private func submitIfReady() {
        if viewModel.isStreaming {
            viewModel.cancel()
            return
        }
        guard viewModel.canSend else { return }
        attachError = nil
        viewModel.send()
    }
}

private struct ReasoningMenu: View {
    let current: ReasoningEffort?
    let onSelect: (ReasoningEffort?) -> Void

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                Label("Default", systemImage: current == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                Button {
                    onSelect(effort)
                } label: {
                    Label(effort.rawValue.capitalized, systemImage: current == effort ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 12))
                Text(label)
                    .font(.caption)
            }
            .foregroundStyle(current == nil ? .secondary : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(current == nil ? Color.gray.opacity(0.08) : Color.accentColor.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reasoning effort for this chat")
    }

    private var label: String {
        switch current {
        case .none: return "Reasoning"
        case .some(let e): return "Reasoning · \(e.rawValue.capitalized)"
        }
    }
}

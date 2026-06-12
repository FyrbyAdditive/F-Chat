// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FyxLocalCore
import FyxLocalTools

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
                            : nil,
                        actions: messageActions(for: viewModel)
                    )
                    // Force SwiftUI to treat each chat as a fresh subtree
                    // so the ScrollView's preserved scroll offset doesn't
                    // bleed across chat switches.
                    .id(conversationID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The model notice is a fixed-height strip pinned to the
                    // composer, NOT a flexible sibling of the transcript in
                    // this VStack — a Spacer-bearing sibling next to the
                    // `maxHeight: .infinity` transcript disrupted the height
                    // negotiation and pushed the toolbar/composer off-screen.
                    Divider()
                    if let notice = viewModel.modelNotice {
                        ModelNoticeBanner(text: notice) { viewModel.modelNotice = nil }
                        Divider()
                    }
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
        // The calendar tool never writes directly: when the model proposes a
        // create/edit/delete it stages it here, and the user must confirm before
        // it commits. Mirrors the sidebar's pendingDeletion confirmation pattern.
        .confirmationDialog(
            environment.pendingCalendarWrite?.summary ?? "Confirm calendar change?",
            isPresented: Binding(
                // Only mirror presence; do NOT clear state in the setter — the
                // dismiss path races the Confirm action otherwise. The buttons
                // own the state transition.
                get: { environment.pendingCalendarWrite != nil },
                set: { _ in }
            ),
            titleVisibility: .visible,
            // Capture the proposal NOW so the dialog's dismissal can't null it
            // out before Confirm's async commit reads it.
            presenting: environment.pendingCalendarWrite
        ) { proposal in
            Button("Confirm", role: proposal.op == .delete ? .destructive : nil) {
                environment.pendingCalendarWrite = nil
                Task { await environment.commitCalendarWrite(proposal) }
            }
            Button("Cancel", role: .cancel) {
                environment.cancelPendingCalendarWrite()
            }
        } message: { _ in
            Text("The assistant proposed this change. It will only happen if you confirm.")
        }
        // Same stage-and-confirm pattern for the reminders tool.
        .confirmationDialog(
            environment.pendingReminderWrite?.summary ?? "Confirm reminder change?",
            isPresented: Binding(
                get: { environment.pendingReminderWrite != nil },
                set: { _ in }
            ),
            titleVisibility: .visible,
            presenting: environment.pendingReminderWrite
        ) { proposal in
            Button("Confirm", role: proposal.op == .delete ? .destructive : nil) {
                environment.pendingReminderWrite = nil
                Task { await environment.commitReminderWrite(proposal) }
            }
            Button("Cancel", role: .cancel) {
                environment.cancelPendingReminderWrite()
            }
        } message: { _ in
            Text("The assistant proposed this change. It will only happen if you confirm.")
        }
        // Warn before a per-message edit/regenerate/delete that would discard
        // later turns. Same stage-and-confirm pattern as the tool writes above:
        // the action stages a `pendingMessageAction` only when discardCount > 0;
        // otherwise it runs immediately with no dialog.
        .confirmationDialog(
            discardWarningTitle(environment.viewModel(for: conversationID)?.pendingMessageAction),
            isPresented: Binding(
                get: { environment.viewModel(for: conversationID)?.pendingMessageAction != nil },
                set: { _ in }
            ),
            titleVisibility: .visible,
            presenting: environment.viewModel(for: conversationID)?.pendingMessageAction
        ) { action in
            Button(confirmLabel(action.kind), role: .destructive) {
                environment.viewModel(for: conversationID)?.commitPendingMessageAction()
            }
            Button("Cancel", role: .cancel) {
                environment.viewModel(for: conversationID)?.cancelPendingMessageAction()
            }
        } message: { action in
            Text("This removes \(action.discardCount) later message(s) from the conversation.")
        }
    }

    /// Build the per-message action set for the transcript. Edit/regenerate/
    /// delete first check whether they'd discard later turns; if so they stage
    /// a `pendingMessageAction` (→ confirmation dialog) instead of running
    /// immediately. With nothing after the target, they run straight away.
    private func messageActions(for viewModel: ChatViewModel) -> MessageActions {
        MessageActions(
            copy: { viewModel.copyMessage($0) },
            edit: { id in
                let after = viewModel.messagesAfter(id)
                if after > 0 {
                    viewModel.pendingMessageAction = .init(kind: .edit, messageID: id, discardCount: after)
                } else {
                    viewModel.editUserMessage(id)
                }
            },
            regenerate: { id in
                let after = viewModel.messagesAfter(id)
                if after > 0 {
                    viewModel.pendingMessageAction = .init(kind: .regenerate, messageID: id, discardCount: after)
                } else {
                    viewModel.regenerateAssistantMessage(id)
                }
            },
            delete: { id in
                let after = viewModel.messagesAfter(id)
                if after > 0 {
                    viewModel.pendingMessageAction = .init(kind: .delete, messageID: id, discardCount: after)
                } else {
                    viewModel.deleteMessage(id)
                }
            },
            isStreaming: viewModel.isStreaming
        )
    }

    private func discardWarningTitle(_ action: ChatViewModel.PendingMessageAction?) -> String {
        switch action?.kind {
        case .edit:       return String(localized: "Edit this message?")
        case .regenerate: return String(localized: "Regenerate this reply?")
        case .delete:     return String(localized: "Delete this message?")
        case nil:         return ""
        }
    }

    private func confirmLabel(_ kind: ChatViewModel.PendingMessageAction.Kind) -> LocalizedStringKey {
        switch kind {
        case .edit:       return "Edit"
        case .regenerate: return "Regenerate"
        case .delete:     return "Delete"
        }
    }
}

/// Informational (non-error) strip above the composer — e.g. "this model
/// can't use tools". Dismissable; also cleared automatically on the next send.
private struct ModelNoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5))
    }
}

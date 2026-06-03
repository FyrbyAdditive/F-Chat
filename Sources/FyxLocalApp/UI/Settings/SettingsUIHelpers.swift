// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI

// Shared UI building blocks for the Settings tabs and their Add/Edit sheets.
// These absorb verbatim-duplicated snippets (a delete-confirmation dialog, a
// monospaced bordered editor, and the Cancel/confirm footer) without coupling
// the tabs themselves — each tab still owns its own layout and form fields.

extension View {
    /// A delete-confirmation dialog driven by an optional "pending id". When
    /// `pendingID` is non-nil the dialog shows; Delete runs `onConfirm` and
    /// clears it, Cancel just clears it. `title`/`message` are built from the
    /// pending id so callers can show item-specific copy.
    ///
    /// Replaces the repeated `confirmationDialog(isPresented: Binding(get/set…))`
    /// dance in AgentsTab / SkillsTab / MCPTab.
    func confirmDeletion<ID: Equatable, Message: View>(
        for pendingID: Binding<ID?>,
        title: (ID) -> LocalizedStringKey,
        @ViewBuilder message: @escaping (ID) -> Message,
        onConfirm: @escaping (ID) -> Void
    ) -> some View {
        let current = pendingID.wrappedValue
        return confirmationDialog(
            current.map(title) ?? "",
            isPresented: Binding(
                get: { pendingID.wrappedValue != nil },
                set: { if !$0 { pendingID.wrappedValue = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingID.wrappedValue { onConfirm(id) }
                pendingID.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { pendingID.wrappedValue = nil }
        } message: {
            if let id = pendingID.wrappedValue { message(id) }
        }
    }

    /// Style a `TextEditor` as a monospaced field with a subtle rounded border
    /// — the look every Settings sheet/card uses for prompt/instruction/JSON
    /// editors.
    func monospacedEditorBorder(minHeight: CGFloat = 140) -> some View {
        self
            .font(.body.monospaced())
            .frame(minHeight: minHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
    }
}

/// The trailing `Cancel` / confirm button row shared by every Add… sheet.
/// `Cancel` uses the cancel shortcut; the confirm button uses the default
/// shortcut and is disabled per `confirmDisabled`.
struct DialogActionButtons: View {
    let confirmLabel: LocalizedStringKey
    var confirmDisabled: Bool = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(confirmLabel, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .disabled(confirmDisabled)
        }
    }
}

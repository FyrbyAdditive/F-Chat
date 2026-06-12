// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FyxLocalCore

struct RootView: View {
    @Bindable var environment: AppEnvironment

    var body: some View {
        NavigationSplitView {
            SidebarView(environment: environment)
                // min wide enough that the three toolbar buttons (Import, Export,
                // New) always fit and never collapse into an overflow menu where
                // they could be stranded.
                .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 360)
        } detail: {
            switch environment.sidebarSelection {
            case .conversation(let id):
                ChatDetailView(environment: environment, conversationID: id)
            case .settings:
                SettingsView(environment: environment)
            case .collections:
                CollectionsView(environment: environment)
            case nil:
                EmptyPlaceholderView()
            }
        }
        .task {
            if environment.conversations.isEmpty {
                environment.newConversation()
            }
            await environment.registerBuiltInTools()
            // Warm the tokenizer cache for any model the user has configured
            // so the meter starts with accurate counts.
            for provider in environment.providerRecords {
                if let model = provider.defaultModel {
                    TokenizerCache.shared.warm(modelID: model)
                }
            }
            // After an embedding-model upgrade, re-embed any collections still
            // on the old model (blocking sheet below shows progress).
            await environment.startReembedIfNeeded()
        }
        // One-time post-upgrade notice (e.g. tools disabled after the rebrand).
        // Presence-driven; the Dismiss button owns clearing the state.
        .sheet(isPresented: Binding(
            get: { !environment.pendingMigrationNotices.isEmpty },
            set: { _ in }
        )) {
            MigrationNoticeSheet(notices: environment.pendingMigrationNotices) {
                environment.pendingMigrationNotices = []
            }
        }
        // Blocking re-embed migration after the embedder model swap.
        .sheet(isPresented: Binding(
            get: { environment.reembedMigrator != nil },
            set: { _ in }
        )) {
            if let migrator = environment.reembedMigrator {
                EmbedderMigrationSheet(migrator: migrator) {
                    environment.finishReembed()
                }
            }
        }
    }
}

struct EmptyPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select or start a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

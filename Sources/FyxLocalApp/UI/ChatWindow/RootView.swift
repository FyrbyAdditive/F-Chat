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
                environment.newConversation(title: "New chat")
            }
            await environment.registerBuiltInTools()
            // Warm the tokenizer cache for any model the user has configured
            // so the meter starts with accurate counts.
            for provider in environment.providerRecords {
                if let model = provider.defaultModel {
                    TokenizerCache.shared.warm(modelID: model)
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

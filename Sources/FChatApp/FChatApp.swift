// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import FChatCore
#if canImport(AppKit)
import AppKit
#endif

@main
struct FChatApp: App {
    @State private var environment = AppEnvironment()
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New chat") {
                    environment.newConversation(title: "New chat")
                }
                .keyboardShortcut("n", modifiers: [.command])
                Divider()
                // Same flow as the sidebar's Import toolbar button — this only
                // asks the sidebar (which owns the picker + wizard) to present.
                Button("Import Chats from File\u{2026}") {
                    environment.requestImportChats()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Chats to File\u{2026}") {
                    environment.requestExportChats()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            // Replace the stock AppKit "About F-Chat" panel with a command
            // that opens the Settings window on its About tab — so there's a
            // single About surface instead of a separate tiny modal.
            CommandGroup(replacing: .appInfo) {
                AboutMenuCommand(environment: environment)
            }
        }

        Settings {
            SettingsView(environment: environment)
        }
    }
}

/// The "About F-Chat" menu item. Sets the Settings selection to the About tab
/// and opens the Settings window via the `openSettings` environment action
/// (hosting it in a view is what gives access to that action from `.commands`).
private struct AboutMenuCommand: View {
    let environment: AppEnvironment
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("About F-Chat") {
            environment.settingsTab = .about
            openSettings()
        }
    }
}

#if canImport(AppKit)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When the binary is launched outside a proper .app bundle (e.g. via
        // `swift run` or `.build/debug/FChat`), macOS leaves the process in
        // a background activation policy. Force it to `.regular` so the
        // window gets a Dock icon, key-window status, and keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

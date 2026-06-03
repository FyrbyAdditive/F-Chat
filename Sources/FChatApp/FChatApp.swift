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

    init() {
        // Ignore SIGPIPE process-wide. We spawn child processes (stdio MCP
        // servers) and write to their stdin; if the child dies, the pipe
        // breaks and writing raises SIGPIPE, whose default action silently
        // kills us with NO crash report. With SIG_IGN the failed write
        // instead returns EPIPE, which FileHandle surfaces as a thrown error
        // our do/catch can handle.
        signal(SIGPIPE, SIG_IGN)
    }

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
            // Settings opens INSIDE the main window's detail pane (the sidebar's
            // Settings row already drives this) rather than a separate window, so
            // we replace SwiftUI's `Settings {}` scene (which always spawns its
            // own window) with our own ⌘, command that selects the settings pane.
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    environment.settingsTab = .providers
                    environment.sidebarSelection = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // "About F-Chat" opens the same in-window pane on its About tab — a
            // single About surface instead of a separate modal.
            CommandGroup(replacing: .appInfo) {
                Button("About F-Chat") {
                    environment.settingsTab = .about
                    environment.sidebarSelection = .settings
                }
            }
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

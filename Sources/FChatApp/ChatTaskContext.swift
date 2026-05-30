// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

/// Task-local context that scopes per-turn inputs (currently: attached RAG
/// collections) to the chat that initiated the turn.
///
/// `ChatViewModel.send` wraps the streamTask body in
/// `ChatTaskContext.$attachedCollections.withValue([...]) { ... }`. The
/// shared `RAGSearchTool` and its retriever read from this when the model
/// invokes a tool, so concurrent streams on different chats never see each
/// other's attached collections. `@TaskLocal` propagates into child tasks
/// (the chat-turn runner spawns one per tool call), so no extra plumbing
/// is needed at tool-invocation time.
enum ChatTaskContext {
    @TaskLocal static var attachedCollections: [CollectionID] = []
    /// Agent Skills enabled for the chat that initiated this turn, as
    /// (name, on-disk directory) pairs. The shared `RunCodeTool` reads this
    /// so it only ever runs code inside a skill the current chat enabled,
    /// and so concurrent chats never see each other's skills.
    @TaskLocal static var enabledSkills: [SkillRuntimeRef] = []
}

/// A per-turn reference to an enabled skill: its name and unpacked directory.
struct SkillRuntimeRef: Sendable, Hashable {
    let name: String
    let directory: URL
}

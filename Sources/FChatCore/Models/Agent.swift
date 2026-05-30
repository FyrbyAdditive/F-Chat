// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// A named system-prompt preset. Each chat references one via
/// `ChatSettings.agentID`; resolution happens at compose time via
/// `AppEnvironment.resolveAgent(for:)`.
///
/// The Default agent (id == `AgentID.defaultAgent`) has `basePrompt == nil`
/// — its system prompt is the localised F-Chat default. Custom agents
/// supply a non-nil `basePrompt` that replaces the localised preamble;
/// F-Chat's tool-use and RAG-use guidance is still auto-appended when
/// those features are active for the chat, so any custom agent keeps
/// working with tools and attached collections.
public struct Agent: Identifiable, Codable, Sendable, Hashable {
    public let id: AgentID
    public var name: String
    public var basePrompt: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: AgentID = AgentID(),
        name: String,
        basePrompt: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.basePrompt = basePrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Last-resort fallback if the persisted agent list is somehow empty
    /// at compose time (shouldn't happen in practice — `AppEnvironment.init`
    /// always seeds Default). Carries a placeholder name; callers should
    /// prefer the seeded entry from `agents` whenever it's present.
    public static var builtInDefault: Agent {
        Agent(id: .defaultAgent, name: "Default", basePrompt: nil)
    }
}

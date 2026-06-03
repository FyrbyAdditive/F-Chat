// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public struct ChatSettings: Codable, Sendable, Hashable {
    public var model: String
    public var providerID: ProviderID
    public var systemPrompt: String?
    /// Which agent (named system-prompt preset) this chat uses. nil resolves
    /// to the global default; `AgentID.defaultAgent` pins to the built-in
    /// preamble. See `AppEnvironment.resolveAgent(for:)`.
    public var agentID: AgentID?
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int?
    public var reasoningEffort: ReasoningEffort?
    public var parallelToolCalls: Bool
    public var maxToolIterations: Int
    public var enabledBuiltInTools: Set<String>
    public var enabledMCPServers: Set<MCPServerID>
    public var attachedCollections: Set<CollectionID>
    public var enabledServerTools: Set<ServerSideTool>
    public var responseStorageMode: ResponseStorageMode
    /// Agent Skills enabled for this chat (a subset of the global library).
    /// Defaults to empty. A custom Decodable (below) decodes it via
    /// `decodeIfPresent` so older state files written before the field existed
    /// still load — Swift's synthesized Decodable does NOT fall back to a
    /// property's default value for a missing key, it throws.
    public var enabledSkills: Set<SkillID> = []

    public init(
        model: String,
        providerID: ProviderID,
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        parallelToolCalls: Bool = true,
        maxToolIterations: Int = 8,
        enabledBuiltInTools: Set<String> = [],
        enabledMCPServers: Set<MCPServerID> = [],
        attachedCollections: Set<CollectionID> = [],
        enabledServerTools: Set<ServerSideTool> = [],
        responseStorageMode: ResponseStorageMode = .serverStored,
        agentID: AgentID? = nil,
        enabledSkills: Set<SkillID> = []
    ) {
        self.model = model
        self.providerID = providerID
        self.systemPrompt = systemPrompt
        self.agentID = agentID
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.parallelToolCalls = parallelToolCalls
        self.maxToolIterations = maxToolIterations
        self.enabledBuiltInTools = enabledBuiltInTools
        self.enabledMCPServers = enabledMCPServers
        self.attachedCollections = attachedCollections
        self.enabledServerTools = enabledServerTools
        self.responseStorageMode = responseStorageMode
        self.enabledSkills = enabledSkills
    }

    private enum CodingKeys: String, CodingKey {
        case model, providerID, systemPrompt, agentID, temperature, topP, maxOutputTokens
        case reasoningEffort, parallelToolCalls, maxToolIterations, enabledBuiltInTools
        case enabledMCPServers, attachedCollections, enabledServerTools, responseStorageMode
        case enabledSkills
    }

    // Custom Decodable so a state file written before `enabledSkills` existed
    // still loads (Swift's synthesized decoder throws keyNotFound rather than
    // using the property default). Every pre-existing field stays required,
    // matching the previous synthesized behaviour.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decode(String.self, forKey: .model)
        self.providerID = try c.decode(ProviderID.self, forKey: .providerID)
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.agentID = try c.decodeIfPresent(AgentID.self, forKey: .agentID)
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        self.topP = try c.decodeIfPresent(Double.self, forKey: .topP)
        self.maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        self.reasoningEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        self.parallelToolCalls = try c.decode(Bool.self, forKey: .parallelToolCalls)
        self.maxToolIterations = try c.decode(Int.self, forKey: .maxToolIterations)
        self.enabledBuiltInTools = try c.decode(Set<String>.self, forKey: .enabledBuiltInTools)
        self.enabledMCPServers = try c.decode(Set<MCPServerID>.self, forKey: .enabledMCPServers)
        self.attachedCollections = try c.decode(Set<CollectionID>.self, forKey: .attachedCollections)
        self.enabledServerTools = try c.decode(Set<ServerSideTool>.self, forKey: .enabledServerTools)
        self.responseStorageMode = try c.decode(ResponseStorageMode.self, forKey: .responseStorageMode)
        self.enabledSkills = try c.decode(Set<SkillID>.self, forKey: .enabledSkills, default: [])
    }
}

public enum ReasoningEffort: String, Codable, Sendable, CaseIterable {
    case minimal, low, medium, high
}

public enum ServerSideTool: String, Codable, Sendable, CaseIterable {
    case webSearch = "web_search"
    case fileSearch = "file_search"
    case codeInterpreter = "code_interpreter"
    case imageGeneration = "image_generation"
}

public enum ResponseStorageMode: String, Codable, Sendable {
    case serverStored
    case stateless
    case statelessEncryptedReasoning
}

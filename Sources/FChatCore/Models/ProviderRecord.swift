import Foundation

public struct ProviderRecord: Identifiable, Sendable, Hashable, Codable {
    public let id: ProviderID
    public var displayName: String
    public var baseURL: URL
    public var defaultModel: String?
    public var capability: ProviderCapability
    public var modelOverrides: [ModelOverride]
    /// Sampling + tool defaults applied to every chat that uses this
    /// provider. Optional so older state files (without this field) load
    /// cleanly; resolved to `.init()` at runtime when absent.
    public var sampling: ProviderSamplingDefaults
    /// Context-budget knobs for auto-compaction. Same back-compat story.
    public var context: ProviderContextSettings

    public init(
        id: ProviderID,
        displayName: String,
        baseURL: URL,
        defaultModel: String? = nil,
        capability: ProviderCapability = .init(),
        modelOverrides: [ModelOverride] = [],
        sampling: ProviderSamplingDefaults = .init(),
        context: ProviderContextSettings = .init()
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.capability = capability
        self.modelOverrides = modelOverrides
        self.sampling = sampling
        self.context = context
    }

    // Custom Decodable to tolerate missing optional fields on old state files.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, baseURL, defaultModel, capability, modelOverrides, sampling, context
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(ProviderID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.baseURL = try c.decode(URL.self, forKey: .baseURL)
        self.defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        self.capability = try c.decodeIfPresent(ProviderCapability.self, forKey: .capability) ?? .init()
        self.modelOverrides = try c.decodeIfPresent([ModelOverride].self, forKey: .modelOverrides) ?? []
        self.sampling = try c.decodeIfPresent(ProviderSamplingDefaults.self, forKey: .sampling) ?? .init()
        self.context = try c.decodeIfPresent(ProviderContextSettings.self, forKey: .context) ?? .init()
    }
}

/// Auto-compaction knobs per provider.
///
/// `hardCap`, when nil, means "use the model's reported context window from
/// `/models` (e.g. vLLM's `max_model_len`), or the known-model catalogue
/// fallback, or a safe 8k default".
public struct ProviderContextSettings: Sendable, Hashable, Codable {
    /// User-supplied ceiling. nil → use the server's model-reported value.
    public var hardCap: Int?
    /// Tokens kept available for the model's reply. The auto-compaction
    /// trigger is `effectiveWindow - outputReserve`: when the projected
    /// input would push us past that point, we compact before sending so
    /// there's always room for the reply.
    public var outputReserve: Int
    /// How many of the most recent messages we keep verbatim when compacting.
    /// The rest get summarized into a single synthetic system message.
    public var recentKeepCount: Int

    public init(hardCap: Int? = nil, outputReserve: Int = 4096, recentKeepCount: Int = 6) {
        self.hardCap = hardCap
        self.outputReserve = max(256, min(64_000, outputReserve))
        self.recentKeepCount = max(2, min(64, recentKeepCount))
    }

    // Custom decoder: tolerate the old `compactThreshold` field by ignoring
    // it. New `outputReserve` defaults to 4096 when missing. Both old and
    // new states load cleanly.
    private enum CodingKeys: String, CodingKey {
        case hardCap, outputReserve, recentKeepCount
        case compactThreshold // legacy; ignored on read, never written
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cap = try c.decodeIfPresent(Int.self, forKey: .hardCap)
        let reserve = try c.decodeIfPresent(Int.self, forKey: .outputReserve) ?? 4096
        let keep = try c.decodeIfPresent(Int.self, forKey: .recentKeepCount) ?? 6
        self.init(hardCap: cap, outputReserve: reserve, recentKeepCount: keep)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(hardCap, forKey: .hardCap)
        try c.encode(outputReserve, forKey: .outputReserve)
        try c.encode(recentKeepCount, forKey: .recentKeepCount)
    }
}

/// Sampling + tool-loop defaults configured per provider in Settings.
/// All chats inherit these directly at request time; there are no per-chat
/// overrides.
public struct ProviderSamplingDefaults: Sendable, Hashable, Codable {
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int?
    public var reasoningEffort: ReasoningEffort?
    public var parallelToolCalls: Bool
    public var maxToolIterations: Int
    public var defaultEnabledBuiltInTools: Set<String>

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        maxOutputTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        parallelToolCalls: Bool = true,
        maxToolIterations: Int = 8,
        defaultEnabledBuiltInTools: Set<String> = ["web_search", "web_fetch"]
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.parallelToolCalls = parallelToolCalls
        self.maxToolIterations = maxToolIterations
        self.defaultEnabledBuiltInTools = defaultEnabledBuiltInTools
    }
}

public struct ProviderCapability: Sendable, Hashable, Codable {
    public var supportsResponses: Bool
    public var supportsEmbeddings: Bool
    public var supportsModelListing: Bool

    public init(
        supportsResponses: Bool = true,
        supportsEmbeddings: Bool = true,
        supportsModelListing: Bool = true
    ) {
        self.supportsResponses = supportsResponses
        self.supportsEmbeddings = supportsEmbeddings
        self.supportsModelListing = supportsModelListing
    }
}

public struct ModelOverride: Sendable, Hashable, Codable {
    public var modelID: String
    public var displayName: String?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsReasoning: Bool

    public init(
        modelID: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        supportsReasoning: Bool = false
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
    }
}

public struct ModelInfo: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var displayName: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsReasoning: Bool

    public init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        supportsReasoning: Bool = false
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
    }
}

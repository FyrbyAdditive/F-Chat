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
/// `hardCap`, when nil, means "use the model's `max_model_len` reported by
/// the server, or fall back to a safe default if missing".
public struct ProviderContextSettings: Sendable, Hashable, Codable {
    /// User-supplied ceiling. nil → use the server's model-reported value.
    public var hardCap: Int?
    /// Fraction of the effective budget at which auto-compaction kicks in.
    /// 0.8 by default; range checked to [0.5, 0.95].
    public var compactThreshold: Double
    /// How many of the most recent messages we keep verbatim when compacting.
    /// The rest get summarized into a single synthetic system message.
    public var recentKeepCount: Int

    public init(hardCap: Int? = nil, compactThreshold: Double = 0.8, recentKeepCount: Int = 6) {
        self.hardCap = hardCap
        self.compactThreshold = max(0.5, min(0.95, compactThreshold))
        self.recentKeepCount = max(2, min(64, recentKeepCount))
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
        defaultEnabledBuiltInTools: Set<String> = ["web_search", "web_fetch", "rag_search"]
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

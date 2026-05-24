import Foundation

/// Effective context window for a chat, with the user's per-provider
/// override applied on top of the server-detected model maximum.
public struct ContextBudget: Sendable, Hashable, Codable {
    public var effectiveWindow: Int
    /// The threshold at which auto-compaction triggers, as an absolute
    /// token count derived from `compactThreshold * effectiveWindow`.
    public var compactionTrigger: Int
    public var recentKeepCount: Int
    public var sourceLabel: String

    public init(
        effectiveWindow: Int,
        compactionTrigger: Int,
        recentKeepCount: Int,
        sourceLabel: String
    ) {
        self.effectiveWindow = effectiveWindow
        self.compactionTrigger = compactionTrigger
        self.recentKeepCount = recentKeepCount
        self.sourceLabel = sourceLabel
    }

    /// Resolve the budget for a provider + (optional) model info combination.
    /// Order of precedence:
    ///   1. The provider's user-supplied `hardCap` if set
    ///   2. The model's reported `contextWindow` from `/models`
    ///   3. A conservative fallback (8192)
    public static func resolve(settings: ProviderContextSettings, model: ModelInfo?) -> ContextBudget {
        let serverHint = model?.contextWindow
        let fallback = 8192
        let effective: Int
        let source: String
        if let cap = settings.hardCap {
            effective = cap
            if let hint = serverHint, cap < hint {
                source = "user cap \(cap) (server: \(hint))"
            } else {
                source = "user cap \(cap)"
            }
        } else if let hint = serverHint {
            effective = hint
            source = "server: \(hint)"
        } else {
            effective = fallback
            source = "fallback: \(fallback)"
        }
        let trigger = max(1, Int(Double(effective) * settings.compactThreshold))
        return ContextBudget(
            effectiveWindow: effective,
            compactionTrigger: trigger,
            recentKeepCount: settings.recentKeepCount,
            sourceLabel: source
        )
    }
}

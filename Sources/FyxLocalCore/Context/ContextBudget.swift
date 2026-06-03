// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// Effective context window for a chat, plus the derived numbers the
/// runtime uses to decide when to compact.
///
/// Semantics:
/// - `effectiveWindow` is the total model context as we understand it
///   (user hard cap, then server-reported max, then catalogue, then
///   8k fallback).
/// - `outputReserve` is tokens we promise to leave free for the model's
///   reply. Reasoning models + a substantive answer can chew through
///   several thousand tokens easily, so we don't want to send so much
///   input that there's no headroom.
/// - `compactionTrigger` is the input-token threshold at which we run
///   the summariser pre-send: it equals `effectiveWindow - outputReserve`
///   (clamped to ≥ 1).
public struct ContextBudget: Sendable, Hashable, Codable {
    public var effectiveWindow: Int
    public var outputReserve: Int
    public var recentKeepCount: Int
    public var sourceLabel: String

    public init(
        effectiveWindow: Int,
        outputReserve: Int,
        recentKeepCount: Int,
        sourceLabel: String
    ) {
        self.effectiveWindow = effectiveWindow
        self.outputReserve = outputReserve
        self.recentKeepCount = recentKeepCount
        self.sourceLabel = sourceLabel
    }

    /// The trigger input-token count: when the projected input is at or
    /// above this, we compact before sending.
    public var compactionTrigger: Int {
        max(1, effectiveWindow - outputReserve)
    }

    /// Same value as `compactionTrigger`, named for the meter UI: how
    /// many input tokens we can safely use before encroaching on the
    /// reserved reply room.
    public var safeInputBudget: Int { compactionTrigger }

    /// Resolve the budget for a provider + (optional) model info combination.
    /// Window precedence:
    ///   1. The provider's user-supplied `hardCap` if set
    ///   2. The model's reported `contextWindow` (server-detected)
    ///   3. The bundled known-model catalogue
    ///   4. A conservative 8k fallback
    public static func resolve(settings: ProviderContextSettings, model: ModelInfo?) -> ContextBudget {
        let serverHint = model?.contextWindow
        let fallback = 8192
        let effective: Int
        let source: String
        if let cap = settings.hardCap {
            effective = cap
            if let hint = serverHint, cap < hint {
                source = "user cap \(cap.formatted()) (server: \(hint.formatted()))"
            } else {
                source = "user cap \(cap.formatted())"
            }
        } else if let hint = serverHint {
            effective = hint
            source = "server: \(hint.formatted())"
        } else {
            effective = fallback
            source = "fallback: \(fallback.formatted())"
        }
        let reserve = settings.outputReserve
        return ContextBudget(
            effectiveWindow: effective,
            outputReserve: reserve,
            recentKeepCount: settings.recentKeepCount,
            sourceLabel: "\(source) · \(reserve.formatted()) reserved for reply"
        )
    }
}

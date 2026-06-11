// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore

public enum StreamEvent: Sendable, Hashable {
    case responseStarted(id: String)
    case textDelta(itemID: String, delta: String)
    case textCompleted(itemID: String, fullText: String)
    case reasoningSummaryDelta(itemID: String, delta: String)
    /// A reasoning/thinking block finished. `signature` is Anthropic's
    /// cryptographic attestation — present means the block must be replayed
    /// verbatim on follow-up requests in a tool-use loop.
    case reasoningCompleted(itemID: String, text: String, signature: String?)
    /// An Anthropic `redacted_thinking` block (opaque, safety-encrypted).
    case redactedThinking(itemID: String, data: String)
    case reasoningEncryptedContent(itemID: String, encrypted: String)
    case toolCallStarted(itemID: String, callID: String, name: String)
    case toolCallArgumentsDelta(itemID: String, callID: String, delta: String)
    case toolCallCompleted(itemID: String, callID: String, name: String, arguments: String)
    case usage(UsageInfo)
    case responseError(message: String, code: String?)
    case completed
}

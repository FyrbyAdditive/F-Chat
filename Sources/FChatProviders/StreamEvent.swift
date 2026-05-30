// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

public enum StreamEvent: Sendable, Hashable {
    case responseStarted(id: String)
    case textDelta(itemID: String, delta: String)
    case textCompleted(itemID: String, fullText: String)
    case reasoningSummaryDelta(itemID: String, delta: String)
    case reasoningEncryptedContent(itemID: String, encrypted: String)
    case toolCallStarted(itemID: String, callID: String, name: String)
    case toolCallArgumentsDelta(itemID: String, callID: String, delta: String)
    case toolCallCompleted(itemID: String, callID: String, name: String, arguments: String)
    case usage(UsageInfo)
    case responseError(message: String, code: String?)
    case completed
}

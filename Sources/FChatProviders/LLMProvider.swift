// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore

public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    func listModels() async throws -> [ModelInfo]
    func streamResponse(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
    func embed(_ texts: [String], model: String) async throws -> [[Float]]
}

public enum ProviderError: Error, Equatable, Sendable, LocalizedError {
    case missingAPIKey
    case httpStatus(Int, body: String)
    case malformedResponse(String)
    case streamTerminatedUnexpectedly
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Provider has no API key configured. Open Settings → Providers and save one to the Keychain."
        case .httpStatus(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = trimmed.count > 600 ? String(trimmed.prefix(600)) + "…" : trimmed
            return "HTTP \(code): \(excerpt.isEmpty ? "<empty body>" : excerpt)"
        case .malformedResponse(let detail):
            return "Malformed response from server: \(detail)"
        case .streamTerminatedUnexpectedly:
            return "The streaming connection ended before the response completed."
        case .unsupported(let detail):
            return "Operation not supported by this provider: \(detail)"
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import FyxLocalProviders

/// Read-only lookup of the user's macOS Contacts. Searches by name / email /
/// phone, or lists all (bounded). NEVER modifies contacts — there is no write
/// path. The actual `CNContactStore` access is provided by an injected
/// `ContactsProvider` so this stays platform-free and testable.
public struct ContactsSearchTool: Tool {
    public let name = "contacts_search"
    public let provider: any ContactsProvider
    public let defaultLimit: Int
    public let maxLimit: Int

    public init(provider: any ContactsProvider, defaultLimit: Int = 25, maxLimit: Int = 100) {
        self.provider = provider
        self.defaultLimit = defaultLimit
        self.maxLimit = maxLimit
    }

    public func definition(for language: PromptLanguage) -> ToolDefinition {
        let description = PromptStrings.string("tool.contacts.desc", language)
        let schema = JSONSchema(raw: #"""
        {"type":"object","properties":{"query":{"type":"string","description":"Optional. Match against name, email, or phone. Omit to list contacts."},"limit":{"type":"integer","minimum":1,"maximum":100,"description":"Max contacts to return (default 25)."}},"additionalProperties":false}
        """#)
        return ToolDefinition(name: name, description: description, parametersSchema: schema, strict: false)
    }

    public func invoke(arguments: String) async throws -> ToolOutput {
        struct Args: Decodable { let query: String?; let limit: Int? }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised = trimmed.isEmpty ? "{}" : trimmed
        guard let data = normalised.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Args.self, from: data) else {
            let message = #"{"error":"Could not parse arguments. Expected {\"query\"?: string, \"limit\"?: integer}. Got: \#(arguments.escapedForJSONInline())"}"#
            return ToolOutput(outputJSON: message, isError: true, display: .markdown)
        }

        // Gate on authorization WITHOUT prompting (the prompt is triggered from
        // Settings → Tools when the user enables the tool). If not granted, tell
        // the model/user how to fix it and do not attempt a fetch.
        let access = await provider.authorization()
        guard access == .authorized else {
            let reason: String
            switch access {
            case .denied: reason = "Contacts access was denied. Allow it in System Settings → Privacy & Security → Contacts."
            case .restricted: reason = "Contacts access is restricted on this Mac (e.g. by a profile or parental controls)."
            case .notDetermined: reason = "Contacts access has not been granted yet. Enable the Contacts tool in Settings → Tools, then allow the macOS prompt."
            case .authorized: reason = ""   // unreachable
            }
            return ToolOutput(outputJSON: #"{"error":"\#(reason.escapedForJSONInline())"}"#, isError: true, display: .markdown)
        }

        let q = parsed.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (q?.isEmpty == false) ? q : nil
        let limit = max(1, min(parsed.limit ?? defaultLimit, maxLimit))
        do {
            let records = try await provider.fetch(query: query, limit: limit)
            let payload = ContactsResultPayload(query: query, count: records.count, contacts: records)
            let json = try JSONEncoder().encode(payload)
            return ToolOutput(outputJSON: String(decoding: json, as: UTF8.self), display: .markdown)
        } catch {
            let message = #"{"error":"contacts_search failed: \#(error.localizedDescription.escapedForJSONInline())"}"#
            return ToolOutput(outputJSON: message, isError: true, display: .markdown)
        }
    }
}

private struct ContactsResultPayload: Encodable {
    let query: String?
    let count: Int
    let contacts: [ContactRecord]
}

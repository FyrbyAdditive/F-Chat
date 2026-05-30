// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public enum MessageRole: String, Codable, Sendable, CaseIterable {
    case system, user, assistant, tool
}

public enum MessageContent: Codable, Sendable, Hashable {
    case text(String)
    case reasoningSummary(String)
    case toolCall(ToolCallRecord)
    case toolResult(ToolResultRecord)
    case image(data: Data, mimeType: String)
    case attachment(filename: String, mimeType: String, data: Data)
}

public struct ToolCallRecord: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public var status: ToolStatus

    public init(id: String, name: String, argumentsJSON: String, status: ToolStatus = .pending) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.status = status
    }
}

public struct ToolResultRecord: Codable, Sendable, Hashable {
    public let callID: String
    public let outputJSON: String
    public let isError: Bool
    public let display: ToolDisplayHint?

    public init(callID: String, outputJSON: String, isError: Bool = false, display: ToolDisplayHint? = nil) {
        self.callID = callID
        self.outputJSON = outputJSON
        self.isError = isError
        self.display = display
    }
}

public enum ToolStatus: String, Codable, Sendable, Hashable {
    case pending, running, succeeded, failed, cancelled
}

public enum ToolDisplayHint: String, Codable, Sendable, Hashable {
    case markdown, image, table, json, htmlIsland, chart
}

public struct UsageInfo: Codable, Sendable, Hashable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int?
    public let cachedInputTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, reasoningTokens: Int? = nil, cachedInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedInputTokens = cachedInputTokens
    }
}

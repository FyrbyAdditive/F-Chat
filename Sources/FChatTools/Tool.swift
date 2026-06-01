// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FChatCore
import FChatProviders

public struct ToolInvocation: Sendable, Hashable {
    public let callID: String
    public let name: String
    public let arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolOutput: Sendable, Hashable {
    public var outputJSON: String
    public var isError: Bool
    public var display: ToolDisplayHint?

    public init(outputJSON: String, isError: Bool = false, display: ToolDisplayHint? = nil) {
        self.outputJSON = outputJSON
        self.isError = isError
        self.display = display
    }
}

public protocol Tool: Sendable {
    var name: String { get }
    func definition(for language: PromptLanguage) -> ToolDefinition
    func invoke(arguments: String) async throws -> ToolOutput
}

public extension Tool {
    /// Standard error result: a single-line `{"error":"…"}` JSON payload with
    /// `isError` set and a markdown display hint. Every built-in tool surfaces
    /// failures this way; the default lives here so they don't each re-declare
    /// it. `message` is JSON-string-escaped (newlines collapsed for inline JSON).
    func errorOutput(_ message: String) -> ToolOutput {
        ToolOutput(
            outputJSON: #"{"error":"\#(message.escapedForJSONInline())"}"#,
            isError: true,
            display: .markdown
        )
    }
}

public enum ToolInvocationError: Error, Sendable, Equatable {
    case timedOut
    case badArguments(String)
    case providerFailure(String)
}

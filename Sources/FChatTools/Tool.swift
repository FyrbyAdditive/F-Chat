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

public enum ToolInvocationError: Error, Sendable, Equatable {
    case timedOut
    case badArguments(String)
    case providerFailure(String)
}

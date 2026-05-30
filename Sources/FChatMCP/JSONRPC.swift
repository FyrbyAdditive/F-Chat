// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public enum JSONRPC {
    public static let version = "2.0"
}

public struct JSONRPCRequest: Sendable, Hashable {
    public let id: JSONRPCID
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCID, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Sendable, Hashable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Sendable, Hashable {
    public let id: JSONRPCID
    public let result: Result<JSONValue, JSONRPCError>

    public init(id: JSONRPCID, result: Result<JSONValue, JSONRPCError>) {
        self.id = id
        self.result = result
    }
}

public struct JSONRPCError: Sendable, Hashable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    public static let internalError = JSONRPCError(code: -32603, message: "Internal error")
}

public enum JSONRPCID: Sendable, Hashable {
    case int(Int)
    case string(String)
}

public enum JSONRPCFrame: Sendable, Hashable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)
}

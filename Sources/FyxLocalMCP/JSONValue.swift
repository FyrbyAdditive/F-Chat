// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public indirect enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(any value: Any) throws {
        if value is NSNull { self = .null; return }
        if let n = value as? NSNumber {
            // NSNumber bridges to Bool for 0/1, so check the underlying Obj-C type first.
            let typeChar = String(cString: n.objCType)
            if typeChar == "c" || typeChar == "B" {
                self = .bool(n.boolValue)
                return
            }
            if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
                return
            }
            self = .int(n.intValue)
            return
        }
        if let b = value as? Bool { self = .bool(b); return }
        if let i = value as? Int { self = .int(i); return }
        if let s = value as? String { self = .string(s); return }
        if let arr = value as? [Any] {
            self = .array(try arr.map(JSONValue.init(any:)))
            return
        }
        if let dict = value as? [String: Any] {
            var obj: [String: JSONValue] = [:]
            for (k, v) in dict { obj[k] = try JSONValue(any: v) }
            self = .object(obj)
            return
        }
        throw JSONRPCError(code: -32700, message: "unsupported JSON value: \(type(of: value))")
    }

    public func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.toAny() }
        case .object(let obj):
            var dict: [String: Any] = [:]
            for (k, v) in obj { dict[k] = v.toAny() }
            return dict
        }
    }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let obj) = self { return obj[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

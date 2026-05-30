// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public enum JSONRPCCodec {
    public static func encode(_ frame: JSONRPCFrame) throws -> Data {
        var obj: [String: Any] = ["jsonrpc": JSONRPC.version]
        switch frame {
        case .request(let req):
            obj["id"] = encode(id: req.id)
            obj["method"] = req.method
            if let p = req.params { obj["params"] = p.toAny() }
        case .notification(let n):
            obj["method"] = n.method
            if let p = n.params { obj["params"] = p.toAny() }
        case .response(let r):
            obj["id"] = encode(id: r.id)
            switch r.result {
            case .success(let v): obj["result"] = v.toAny()
            case .failure(let e):
                var err: [String: Any] = ["code": e.code, "message": e.message]
                if let d = e.data { err["data"] = d.toAny() }
                obj["error"] = err
            }
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [])
    }

    public static func decode(_ data: Data) throws -> JSONRPCFrame {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSONRPCError.parseError
        }
        if let result = raw["result"] {
            let id = try decode(id: raw["id"])
            let value = try JSONValue(any: result)
            return .response(.init(id: id, result: .success(value)))
        }
        if let errorObj = raw["error"] as? [String: Any] {
            let id = try decode(id: raw["id"])
            let code = (errorObj["code"] as? Int) ?? -32603
            let message = (errorObj["message"] as? String) ?? "unknown error"
            let dataValue = try errorObj["data"].map(JSONValue.init(any:))
            return .response(.init(id: id, result: .failure(.init(code: code, message: message, data: dataValue))))
        }
        guard let method = raw["method"] as? String else { throw JSONRPCError.parseError }
        let params = try raw["params"].map(JSONValue.init(any:))
        if raw["id"] != nil {
            let id = try decode(id: raw["id"])
            return .request(.init(id: id, method: method, params: params))
        }
        return .notification(.init(method: method, params: params))
    }

    private static func encode(id: JSONRPCID) -> Any {
        switch id {
        case .int(let i): return i
        case .string(let s): return s
        }
    }

    private static func decode(id: Any?) throws -> JSONRPCID {
        switch id {
        case let i as Int: return .int(i)
        case let s as String: return .string(s)
        case let n as NSNumber: return .int(n.intValue)
        default: throw JSONRPCError.parseError
        }
    }
}

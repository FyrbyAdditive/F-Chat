// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatMCP

@Suite("JSONRPCCodec")
struct JSONRPCCodecTests {
    @Test func encodesRequestWithIntID() throws {
        let frame = JSONRPCFrame.request(.init(id: .int(7), method: "ping", params: .object(["x": .int(1)])))
        let data = try JSONRPCCodec.encode(frame)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["jsonrpc"] as? String == "2.0")
        #expect(obj["id"] as? Int == 7)
        #expect(obj["method"] as? String == "ping")
        let params = try #require(obj["params"] as? [String: Any])
        #expect(params["x"] as? Int == 1)
    }

    @Test func decodesSuccessResponse() throws {
        let json = #"{"jsonrpc":"2.0","id":3,"result":{"ok":true,"value":42}}"#.data(using: .utf8)!
        let frame = try JSONRPCCodec.decode(json)
        guard case .response(let r) = frame else { Issue.record("expected response"); return }
        #expect(r.id == .int(3))
        guard case .success(let value) = r.result else { Issue.record("expected success"); return }
        #expect(value["ok"] == .bool(true))
        #expect(value["value"] == .int(42))
    }

    @Test func decodesErrorResponse() throws {
        let json = #"{"jsonrpc":"2.0","id":"abc","error":{"code":-32601,"message":"not found"}}"#.data(using: .utf8)!
        let frame = try JSONRPCCodec.decode(json)
        guard case .response(let r) = frame else { Issue.record("expected response"); return }
        guard case .failure(let err) = r.result else { Issue.record("expected failure"); return }
        #expect(err.code == -32601)
        #expect(err.message == "not found")
    }

    @Test func decodesNotification() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.data(using: .utf8)!
        let frame = try JSONRPCCodec.decode(json)
        guard case .notification(let n) = frame else { Issue.record("expected notification"); return }
        #expect(n.method == "notifications/tools/list_changed")
    }

    @Test func roundTripsResponseFrame() throws {
        let frame = JSONRPCFrame.response(.init(id: .string("z"), result: .success(.array([.int(1), .int(2)]))))
        let encoded = try JSONRPCCodec.encode(frame)
        let decoded = try JSONRPCCodec.decode(encoded)
        #expect(decoded == frame)
    }
}

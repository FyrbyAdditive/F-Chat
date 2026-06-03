// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

public protocol MCPTransport: Sendable {
    func send(_ frame: JSONRPCFrame) async throws
    func incoming() -> AsyncThrowingStream<JSONRPCFrame, Error>
    func close() async
}

public enum MCPTransportError: Error, Sendable, Equatable {
    case closed
    case protocolError(String)
    case ioError(String)
}

/// Simple paired in-memory transport. Two endpoints share a single channel:
/// `clientToServer` and `serverToClient`. Useful for tests and mock servers.
public actor InMemoryMCPTransport: MCPTransport {
    private var outbound: AsyncStream<JSONRPCFrame>.Continuation?
    private let inboundStream: AsyncStream<JSONRPCFrame>
    private let inboundContinuation: AsyncStream<JSONRPCFrame>.Continuation
    private var closed = false

    public init(
        outbound: AsyncStream<JSONRPCFrame>.Continuation? = nil,
        inbound: AsyncStream<JSONRPCFrame>
    ) {
        self.outbound = outbound
        var cont: AsyncStream<JSONRPCFrame>.Continuation!
        self.inboundStream = AsyncStream<JSONRPCFrame> { c in cont = c }
        self.inboundContinuation = cont
        Task { await self.relayInbound(from: inbound) }
    }

    public func setOutbound(_ continuation: AsyncStream<JSONRPCFrame>.Continuation) {
        self.outbound = continuation
    }

    public func send(_ frame: JSONRPCFrame) async throws {
        guard !closed, let outbound else { throw MCPTransportError.closed }
        outbound.yield(frame)
    }

    nonisolated public func incoming() -> AsyncThrowingStream<JSONRPCFrame, Error> {
        AsyncThrowingStream(JSONRPCFrame.self) { continuation in
            let task = Task { await self.deliver(to: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func deliver(to continuation: AsyncThrowingStream<JSONRPCFrame, Error>.Continuation) async {
        for await frame in inboundStream {
            continuation.yield(frame)
        }
        continuation.finish()
    }

    public func close() async {
        closed = true
        outbound?.finish()
        inboundContinuation.finish()
    }

    private func relayInbound(from stream: AsyncStream<JSONRPCFrame>) async {
        for await frame in stream { inboundContinuation.yield(frame) }
        inboundContinuation.finish()
    }
}

/// Creates a connected pair of transports. Anything sent on one appears on the other's inbound.
public func makeInMemoryTransportPair() async -> (InMemoryMCPTransport, InMemoryMCPTransport) {
    var aToBCont: AsyncStream<JSONRPCFrame>.Continuation!
    let aToBStream = AsyncStream<JSONRPCFrame> { c in aToBCont = c }
    var bToACont: AsyncStream<JSONRPCFrame>.Continuation!
    let bToAStream = AsyncStream<JSONRPCFrame> { c in bToACont = c }

    let a = InMemoryMCPTransport(outbound: aToBCont, inbound: bToAStream)
    let b = InMemoryMCPTransport(outbound: bToACont, inbound: aToBStream)
    return (a, b)
}

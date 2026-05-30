// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

#if canImport(Darwin)
public actor StdioMCPTransport: MCPTransport {
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: String?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var inboundContinuation: AsyncThrowingStream<JSONRPCFrame, Error>.Continuation?
    private var readerTask: Task<Void, Never>?

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }
        if let wd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading
    }

    public func send(_ frame: JSONRPCFrame) async throws {
        guard let stdinHandle else { throw MCPTransportError.closed }
        var data = try JSONRPCCodec.encode(frame)
        data.append(0x0A) // newline
        try stdinHandle.write(contentsOf: data)
    }

    nonisolated public func incoming() -> AsyncThrowingStream<JSONRPCFrame, Error> {
        AsyncThrowingStream(JSONRPCFrame.self) { continuation in
            let task = Task { await self.startReading(into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func startReading(into continuation: AsyncThrowingStream<JSONRPCFrame, Error>.Continuation) async {
        self.inboundContinuation = continuation
        guard let stdoutHandle else {
            continuation.finish(throwing: MCPTransportError.closed)
            return
        }
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            await self?.readLoop(handle: stdoutHandle)
        }
    }

    private func readLoop(handle: FileHandle) async {
        var buffer = Data()
        for await chunk in handle.bytes {
            if Task.isCancelled { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                do {
                    let frame = try JSONRPCCodec.decode(Data(line))
                    inboundContinuation?.yield(frame)
                } catch {
                    inboundContinuation?.finish(throwing: MCPTransportError.protocolError("decode: \(error)"))
                    return
                }
            }
        }
        inboundContinuation?.finish()
    }

    public func close() async {
        readerTask?.cancel()
        readerTask = nil
        try? stdinHandle?.close()
        process?.terminate()
        process?.waitUntilExit()
        inboundContinuation?.finish()
    }
}

extension FileHandle {
    fileprivate var bytes: AsyncStream<UInt8> {
        AsyncStream<UInt8>(bufferingPolicy: .unbounded) { continuation in
            let handle = self
            let queue = DispatchQueue(label: "fchat.mcp.stdio.reader")
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    continuation.finish()
                    handle.readabilityHandler = nil
                    return
                }
                queue.async {
                    for byte in data { continuation.yield(byte) }
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}
#endif

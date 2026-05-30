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
    /// Image / attachment bytes live in the on-disk `BlobStore`, referenced by
    /// `BlobRef` — they are NOT stored inline in the conversation (which would
    /// bloat state.json + RAM and hash huge blobs). Use the `image(data:…)` /
    /// `attachment(filename:…)` constructors to write bytes into the store, and
    /// `imageData` / `attachmentData` to read them back on demand.
    case image(BlobRef)
    case attachment(BlobRef)

    // MARK: - Ergonomic constructors (write bytes into the shared BlobStore)

    /// Build an `.image` from raw bytes, persisting them to the blob store.
    /// Returns `.text("[image]")`-free: on a store failure the bytes are still
    /// referenced by an in-memory ref whose read will fail gracefully.
    public static func image(data: Data, mimeType: String) -> MessageContent {
        let ref = (try? BlobStore.shared.put(data, mimeType: mimeType))
            ?? BlobRef(sha256: BlobStore.sha256Hex(data), mimeType: mimeType, byteCount: data.count)
        return .image(ref)
    }

    public static func attachment(filename: String, mimeType: String, data: Data) -> MessageContent {
        let ref = (try? BlobStore.shared.put(data, mimeType: mimeType, filename: filename))
            ?? BlobRef(sha256: BlobStore.sha256Hex(data), mimeType: mimeType, byteCount: data.count, filename: filename)
        return .attachment(ref)
    }

    // MARK: - Byte accessors (read from the store on demand)

    public var imageData: Data? {
        guard case .image(let ref) = self else { return nil }
        return try? BlobStore.shared.data(for: ref)
    }

    public var attachmentData: Data? {
        guard case .attachment(let ref) = self else { return nil }
        return try? BlobStore.shared.data(for: ref)
    }

    /// All blob hashes this content references (for GC roots).
    public var blobHashes: [String] {
        switch self {
        case .image(let ref), .attachment(let ref): return [ref.sha256]
        default: return []
        }
    }

    // MARK: - Codable (back-compatible with the old inline-base64 shape)

    private enum CodingKeys: String, CodingKey {
        case type, text, record, ref
        // Legacy inline fields (pre-blob-store):
        case data, mimeType, filename
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "reasoningSummary":
            self = .reasoningSummary(try c.decode(String.self, forKey: .text))
        case "toolCall":
            self = .toolCall(try c.decode(ToolCallRecord.self, forKey: .record))
        case "toolResult":
            self = .toolResult(try c.decode(ToolResultRecord.self, forKey: .record))
        case "image":
            // New shape: a BlobRef. Old shape: inline `data` (base64) + `mimeType`.
            if let ref = try c.decodeIfPresent(BlobRef.self, forKey: .ref) {
                self = .image(ref)
            } else {
                let data = try c.decode(Data.self, forKey: .data)
                let mime = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
                self = .image(data: data, mimeType: mime)   // migrates into the blob store
            }
        case "attachment":
            if let ref = try c.decodeIfPresent(BlobRef.self, forKey: .ref) {
                self = .attachment(ref)
            } else {
                let data = try c.decode(Data.self, forKey: .data)
                let mime = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
                let name = try c.decodeIfPresent(String.self, forKey: .filename)
                self = .attachment(filename: name ?? "attachment", mimeType: mime, data: data)
            }
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown MessageContent type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type); try c.encode(s, forKey: .text)
        case .reasoningSummary(let s):
            try c.encode("reasoningSummary", forKey: .type); try c.encode(s, forKey: .text)
        case .toolCall(let r):
            try c.encode("toolCall", forKey: .type); try c.encode(r, forKey: .record)
        case .toolResult(let r):
            try c.encode("toolResult", forKey: .type); try c.encode(r, forKey: .record)
        case .image(let ref):
            try c.encode("image", forKey: .type); try c.encode(ref, forKey: .ref)
        case .attachment(let ref):
            try c.encode("attachment", forKey: .type); try c.encode(ref, forKey: .ref)
        }
    }
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

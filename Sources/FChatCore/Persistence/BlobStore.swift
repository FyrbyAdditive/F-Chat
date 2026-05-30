// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import CryptoKit

/// A reference to a binary blob (image / attachment) stored on disk by content
/// hash, instead of inline in `state.json`. Carries just enough metadata to
/// render and round-trip without loading the bytes.
public struct BlobRef: Codable, Sendable, Hashable {
    public let sha256: String
    public let mimeType: String
    public let byteCount: Int
    public let filename: String?

    public init(sha256: String, mimeType: String, byteCount: Int, filename: String? = nil) {
        self.sha256 = sha256
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.filename = filename
    }
}

/// Content-addressed on-disk store for message image/attachment bytes. Keeping
/// large `Data` out of `Conversation` means `state.json` stays small, blobs
/// aren't decoded on every launch, and only the visible message that needs an
/// image actually reads it. Identical bytes dedupe to one file.
public final class BlobStore: Sendable {
    private let root: URL

    /// Process-wide default under `…/F-Chat/blobs`. The model layer reaches the
    /// store through `BlobStore.shared` so encode/decode + views don't need it
    /// injected.
    public static let shared = BlobStore(root: AppDataDirectories.subdirectory("blobs"))

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func url(forHash hash: String) -> URL {
        root.appendingPathComponent(hash, isDirectory: false)
    }

    /// Store bytes (deduped by SHA-256) and return a reference. Writing is
    /// atomic; an existing blob with the same hash is left untouched.
    @discardableResult
    public func put(_ data: Data, mimeType: String, filename: String? = nil) throws -> BlobRef {
        let hash = Self.sha256Hex(data)
        let dest = url(forHash: hash)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try data.write(to: dest, options: [.atomic])
        }
        return BlobRef(sha256: hash, mimeType: mimeType, byteCount: data.count, filename: filename)
    }

    /// Read the bytes for a reference. Throws if the blob is missing.
    public func data(for ref: BlobRef) throws -> Data {
        try Data(contentsOf: url(forHash: ref.sha256))
    }

    public func contains(_ ref: BlobRef) -> Bool {
        FileManager.default.fileExists(atPath: url(forHash: ref.sha256).path)
    }

    /// Delete every blob whose hash is not in `keeping`. Call after pruning
    /// conversations to reclaim space.
    public func garbageCollect(keeping hashes: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !hashes.contains(entry.lastPathComponent) {
            try? fm.removeItem(at: entry)
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

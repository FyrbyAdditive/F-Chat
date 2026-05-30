// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
@testable import FChatCore

@Suite("BlobStore + MessageContent migration")
struct BlobStoreTests {
    private func tempStore() -> BlobStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobtest-\(UUID().uuidString)", isDirectory: true)
        return BlobStore(root: dir)
    }

    @Test func putGetRoundTripsAndDedupes() throws {
        let store = tempStore()
        let data = Data("hello bytes".utf8)
        let ref1 = try store.put(data, mimeType: "text/plain", filename: "a.txt")
        let ref2 = try store.put(data, mimeType: "text/plain", filename: "b.txt")
        #expect(ref1.sha256 == ref2.sha256)              // same bytes → same hash (dedupe)
        #expect(ref1.byteCount == data.count)
        #expect(try store.data(for: ref1) == data)
        #expect(store.contains(ref1))
    }

    @Test func garbageCollectDropsUnreferenced() throws {
        let store = tempStore()
        let keep = try store.put(Data("keep".utf8), mimeType: "text/plain")
        let drop = try store.put(Data("drop".utf8), mimeType: "text/plain")
        store.garbageCollect(keeping: [keep.sha256])
        #expect(store.contains(keep))
        #expect(!store.contains(drop))
    }

    @Test func messageContentImageEncodesAsRefNotBytes() throws {
        // New shape: encoding an image must NOT embed the raw bytes (the whole
        // point — keep state.json small). It stores a BlobRef.
        let content = MessageContent.image(data: Data(repeating: 0xAB, count: 4096), mimeType: "image/png")
        let json = try JSONEncoder().encode(content)
        let str = String(decoding: json, as: UTF8.self)
        #expect(str.contains("\"ref\""))
        #expect(str.contains("sha256"))
        // 4 KB of 0xAB base64-encoded would be huge; assert the encoded form is small.
        #expect(json.count < 300)
    }

    @Test func decodesLegacyInlineImageIntoBlobStore() throws {
        // Old state.json shape: image with inline base64 `data` + `mimeType`.
        let bytes = Data("legacy-image-bytes".utf8)
        let legacy = """
        { "type": "image", "data": "\(bytes.base64EncodedString())", "mimeType": "image/jpeg" }
        """
        let content = try JSONDecoder().decode(MessageContent.self, from: Data(legacy.utf8))
        guard case .image(let ref) = content else { Issue.record("expected .image"); return }
        #expect(ref.mimeType == "image/jpeg")
        #expect(ref.byteCount == bytes.count)
        // The bytes were migrated into the shared store and are recoverable.
        #expect(content.imageData == bytes)
    }

    @Test func decodesLegacyInlineAttachmentIntoBlobStore() throws {
        let bytes = Data("legacy-attachment".utf8)
        let legacy = """
        { "type": "attachment", "filename": "notes.txt", "mimeType": "text/plain", "data": "\(bytes.base64EncodedString())" }
        """
        let content = try JSONDecoder().decode(MessageContent.self, from: Data(legacy.utf8))
        guard case .attachment(let ref) = content else { Issue.record("expected .attachment"); return }
        #expect(ref.filename == "notes.txt")
        #expect(content.attachmentData == bytes)
    }

    @Test func newRefShapeRoundTripsThroughCodable() throws {
        let original = MessageContent.attachment(filename: "f.bin", mimeType: "application/octet-stream", data: Data([1, 2, 3]))
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessageContent.self, from: encoded)
        #expect(decoded == original)
    }
}

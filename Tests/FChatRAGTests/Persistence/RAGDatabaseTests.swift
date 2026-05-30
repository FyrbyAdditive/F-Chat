// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import GRDB
@testable import FChatRAG

@Suite("RAGDatabase")
struct RAGDatabaseTests {
    private func makeTmpDB() throws -> RAGDatabase {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rag-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rag.sqlite")
        return try RAGDatabase(fileURL: tmp)
    }

    @Test func opensAndReportsVecVersion() throws {
        let db = try makeTmpDB()
        let version = try db.vecVersion()
        #expect(version.hasPrefix("v0."))
        try? FileManager.default.removeItem(at: db.fileURL.deletingLastPathComponent())
    }

    @Test func schemaCreatedExpectedTables() throws {
        let db = try makeTmpDB()
        let tables = try db.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        #expect(tables.contains("collections"))
        #expect(tables.contains("documents"))
        #expect(tables.contains("chunks"))
        try? FileManager.default.removeItem(at: db.fileURL.deletingLastPathComponent())
    }

    @Test func canCreateVec0VirtualTable() throws {
        // Real sqlite-vec sanity: actually instantiate a vec0 vtable and
        // round-trip a vector. This is the test that proves the extension
        // is loaded — if installSQLiteVec failed, CREATE VIRTUAL TABLE
        // would error with "no such module: vec0".
        let db = try makeTmpDB()
        try db.queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE test_vec USING vec0(id TEXT PRIMARY KEY, embedding FLOAT[3])")
            try db.execute(sql: "INSERT INTO test_vec(id, embedding) VALUES ('a', vec_f32(?))", arguments: ["[1.0, 0.0, 0.0]"])
        }
        let count = try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM test_vec") ?? -1
        }
        #expect(count == 1)
        try? FileManager.default.removeItem(at: db.fileURL.deletingLastPathComponent())
    }

    @Test func migrationsAreIdempotent() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rag-idem-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rag.sqlite")
        let a = try RAGDatabase(fileURL: url)
        _ = a // close happens when a is deallocated
        let b = try RAGDatabase(fileURL: url) // second open should be a no-op
        let tables = try b.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        #expect(tables.contains("collections"))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

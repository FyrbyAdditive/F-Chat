// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import GRDB
import CSQLiteVec
import FChatCore

/// SQLite-backed home for collections, documents, chunks, and per-collection
/// vector tables (sqlite-vec).
///
/// One file per app install at `~/Library/Application Support/F-Chat/rag.sqlite`.
/// Migrations are idempotent; schema additions go in numbered migrations
/// rather than altering existing ones.
public final class RAGDatabase: Sendable {
    public let queue: DatabaseQueue
    public let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        // Load the statically-linked sqlite-vec extension on every new
        // connection. Without this, `vec0` is unknown to SQL.
        config.prepareDatabase { db in
            try RAGDatabase.installSQLiteVec(into: db)
        }
        self.queue = try DatabaseQueue(path: fileURL.path, configuration: config)
        try migrator.migrate(queue)
    }

    /// Opens the default-location database under Application Support.
    public static func openDefault() throws -> RAGDatabase {
        let url = AppDataDirectories.ensureRoot().appendingPathComponent("rag.sqlite")
        return try RAGDatabase(fileURL: url)
    }

    /// Register sqlite-vec's functions on the open database. CSQLiteVec
    /// vendors the amalgamation compiled with `SQLITE_CORE`, so we call
    /// `sqlite3_vec_init` directly against the GRDB-owned `sqlite3*` handle.
    static func installSQLiteVec(into db: Database) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_vec_init(db.sqliteConnection, &errMsg, nil)
        if rc != SQLITE_OK {
            let detail: String
            if let errMsg {
                detail = String(cString: errMsg)
                sqlite3_free(errMsg)
            } else {
                detail = "rc=\(rc)"
            }
            throw RAGDatabaseError.extensionLoadFailed(detail)
        }
    }

    /// `SELECT vec_version()` for sanity-check tests.
    public func vecVersion() throws -> String {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT vec_version()") ?? ""
        }
    }

    // MARK: - Schema

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_initial") { db in
            try db.create(table: "collections") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("summary", .text)
                t.column("embedder_kind", .text).notNull()
                t.column("embedding_model", .text).notNull()
                t.column("dim", .integer).notNull()
                t.column("distance", .text).notNull()
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }

            try db.create(table: "documents") { t in
                t.column("id", .text).primaryKey()
                t.column("collection_id", .text).notNull()
                    .references("collections", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("source_path", .text)
                t.column("content_hash", .text).notNull()
                t.column("ingested_at", .double).notNull()
                t.column("byte_size", .integer).notNull()
                t.column("parse_error", .text)
                t.column("chunk_count", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "documents_collection_idx", on: "documents", columns: ["collection_id"])

            try db.create(table: "chunks") { t in
                t.column("id", .text).primaryKey()
                t.column("document_id", .text).notNull()
                    .references("documents", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("page", .integer)
                t.column("section", .text)
                t.column("language", .text)
                t.column("token_count", .integer)
            }
            try db.create(index: "chunks_document_idx", on: "chunks", columns: ["document_id"])
        }

        return m
    }
}

public enum RAGDatabaseError: Error, Equatable, Sendable {
    case extensionLoadFailed(String)
    case unknownCollection
    case dimensionMismatch(expected: Int, got: Int)
}

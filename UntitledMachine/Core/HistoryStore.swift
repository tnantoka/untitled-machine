//
//  HistoryStore.swift
//  UntitledMachine
//
//  The persistence layer. All storage details stay behind this boundary, so a
//  future swap (e.g. SQLCipher) stays contained here.
//
//  Schema is a single FTS5 virtual table that doubles as storage and full-text
//  index: no triggers, no external-content table, less to break. The `trigram`
//  tokenizer gives substring search for any script, including Japanese. We use
//  the table's rowid as the id; rows are inserted in time order, so
//  `ORDER BY rowid DESC` is "newest first" without an extra index.
//

import Foundation
import CryptoKit
import SQLite3

// The magic value SQLite expects to mean "copy the bound text" (SQLITE_TRANSIENT).
private nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Off the main actor so it can run on the capture queue, a background search
// task, and test threads. Opened with SQLITE_OPEN_FULLMUTEX, so the C layer
// serializes access; the only stored state (`db`) is immutable after init.
// Hence @unchecked Sendable: thread-safe by construction, not by the compiler.
nonisolated final class HistoryStore: @unchecked Sendable {

    enum StoreError: Error, CustomStringConvertible {
        case open(String)
        case sql(String)

        var description: String {
            switch self {
            case .open(let m): return "cannot open database: \(m)"
            case .sql(let m): return "SQL error: \(m)"
            }
        }
    }

    private var db: OpaquePointer?

    /// The caller must ensure the parent directory exists.
    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw StoreError.open(msg)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS snapshots USING fts5(
                content,
                created_at UNINDEXED,
                byte_count UNINDEXED,
                hash UNINDEXED,
                tokenize='trigram'
            );
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writing

    /// Returns nil when the content is identical to the latest snapshot, which
    /// guards against duplicate FSEvents firing for the same save.
    @discardableResult
    func appendSnapshot(content: String, createdAt: Date) throws -> Snapshot? {
        let hash = Self.sha256Hex(content)
        if let latest = try latestHash(), latest == hash {
            return nil
        }

        let byteCount = content.utf8.count
        let stmt = try prepare("""
            INSERT INTO snapshots (content, created_at, byte_count, hash)
            VALUES (?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, createdAt.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 3, Int64(byteCount))
        sqlite3_bind_text(stmt, 4, hash, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }

        let id = sqlite3_last_insert_rowid(db)
        return Snapshot(id: id, createdAt: createdAt, content: content)
    }

    func deleteSnapshot(id: Int64) throws {
        let stmt = try prepare("DELETE FROM snapshots WHERE rowid = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    /// Deletes many versions in one transaction (all-or-nothing).
    func deleteSnapshots(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try exec("BEGIN;")
        do {
            let stmt = try prepare("DELETE FROM snapshots WHERE rowid = ?;")
            defer { sqlite3_finalize(stmt) }
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, id)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Reading

    func snapshotMetas() throws -> [SnapshotMeta] {
        let stmt = try prepare("""
            SELECT rowid, created_at, byte_count FROM snapshots ORDER BY rowid DESC;
            """)
        defer { sqlite3_finalize(stmt) }

        var result: [SnapshotMeta] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(SnapshotMeta(
                id: sqlite3_column_int64(stmt, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                byteCount: Int(sqlite3_column_int64(stmt, 2))
            ))
        }
        return result
    }

    func content(id: Int64) throws -> String? {
        let stmt = try prepare("SELECT content FROM snapshots WHERE rowid = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    func snapshot(id: Int64) throws -> Snapshot? {
        let stmt = try prepare("SELECT created_at, content FROM snapshots WHERE rowid = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Snapshot(
            id: id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
            content: String(cString: sqlite3_column_text(stmt, 1))
        )
    }

    func latest() throws -> Snapshot? {
        let stmt = try prepare("""
            SELECT rowid, created_at, content FROM snapshots ORDER BY rowid DESC LIMIT 1;
            """)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Snapshot(
            id: sqlite3_column_int64(stmt, 0),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            content: String(cString: sqlite3_column_text(stmt, 2))
        )
    }

    /// Content of the version immediately older than `id`, for diffing against it.
    func previousContent(before id: Int64) throws -> String? {
        let stmt = try prepare("SELECT content FROM snapshots WHERE rowid < ? ORDER BY rowid DESC LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    func count() throws -> Int {
        let stmt = try prepare("SELECT count(*) FROM snapshots;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Search

    /// Finds every snapshot containing the query, newest first.
    func search(_ rawQuery: String) throws -> [SnapshotMeta] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let stmt: OpaquePointer?
        if query.count >= 3 {
            // trigram works in 3-grams, so match the query as a phrase.
            let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            stmt = try prepare("""
                SELECT rowid, created_at, byte_count FROM snapshots
                WHERE snapshots MATCH ? ORDER BY rowid DESC;
                """)
            sqlite3_bind_text(stmt, 1, phrase, -1, SQLITE_TRANSIENT)
        } else {
            // Queries shorter than 3 chars can't use the trigram index, so scan with LIKE.
            let pattern = "%" + escapeLike(query) + "%"
            stmt = try prepare("""
                SELECT rowid, created_at, byte_count FROM snapshots
                WHERE content LIKE ? ESCAPE '\\' ORDER BY rowid DESC;
                """)
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
        }
        defer { sqlite3_finalize(stmt) }

        var result: [SnapshotMeta] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(SnapshotMeta(
                id: sqlite3_column_int64(stmt, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                byteCount: Int(sqlite3_column_int64(stmt, 2))
            ))
        }
        return result
    }

    // MARK: - Helpers

    private func latestHash() throws -> String? {
        let stmt = try prepare("SELECT hash FROM snapshots ORDER BY rowid DESC LIMIT 1;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        return stmt
    }

    private func lastError() -> StoreError {
        .sql(String(cString: sqlite3_errmsg(db)))
    }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

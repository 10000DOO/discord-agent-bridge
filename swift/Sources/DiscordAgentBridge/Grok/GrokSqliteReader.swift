import SQLite3
import Foundation

// Read <grokHome>/sessions/session_search.sqlite via the system libsqlite3 C API. Same
// memory-deserialize, read-only pattern as Codex/CodexSqliteReader.swift (1:1 port of
// src/modes/grok/discovery.ts — that TS file's own header notes it uses "the same read-only,
// byte-copy pattern as modes/codex/sqliteReader.ts" without sharing code, so this mirrors that
// choice rather than introducing a cross-backend util). Table is `session_docs`, one row per
// Grok session, updated_at in epoch SECONDS (Codex's threads table uses updated_at_ms).
//
// Opens the db READ-ONLY from an in-memory byte copy (sqlite3_deserialize) so the live
// ~/.grok file is never written to or locked. Any open/read/parse failure throws
// GrokSqliteError; GrokDiscovery catches that to degrade to "no resumable sessions" (matches
// TS GrokDiscovery.listResumable's try/catch → []).

public struct GrokSessionDocRow: Sendable, Equatable {
    public var sessionId: String
    public var cwd: String
    public var updatedAt: Int64?
    public var title: String?
}

public struct GrokSqliteError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public enum GrokSqliteReader {
    // Read session_docs rows from a specific session_search.sqlite file, newest first.
    public static func readSessionDocsFromFile(_ dbPath: String) throws -> [GrokSessionDocRow] {
        guard let data = FileManager.default.contents(atPath: dbPath) else {
            throw GrokSqliteError("Failed to read Grok session db: \(dbPath)")
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw GrokSqliteError("Failed to initialize sqlite3 engine")
        }
        defer { sqlite3_close(db) }

        guard let buf = sqlite3_malloc64(sqlite3_uint64(data.count)) else {
            throw GrokSqliteError("Failed to query Grok session db: \(dbPath)")
        }
        data.withUnsafeBytes { raw in
            _ = memcpy(buf, raw.baseAddress, data.count)
        }
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE) | UInt32(SQLITE_DESERIALIZE_READONLY)
        guard sqlite3_deserialize(
            db, "main", buf.assumingMemoryBound(to: UInt8.self), Int64(data.count), Int64(data.count), flags
        ) == SQLITE_OK else {
            throw GrokSqliteError("Failed to query Grok session db: \(dbPath)")
        }

        guard let rows = queryDocs(db) else {
            throw GrokSqliteError("Failed to query Grok session db: \(dbPath)")
        }
        return rows
    }
}

// MARK: - SQL helpers

private func queryDocs(_ db: OpaquePointer?) -> [GrokSessionDocRow]? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(
        db, "SELECT session_id, cwd, updated_at, title FROM session_docs ORDER BY updated_at DESC", -1, &stmt, nil
    ) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }

    var rows: [GrokSessionDocRow] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let sessionId = columnText(stmt, 0) else { continue }
        rows.append(GrokSessionDocRow(
            sessionId: sessionId,
            cwd: columnText(stmt, 1) ?? "",
            updatedAt: columnInt64(stmt, 2),
            title: columnText(stmt, 3)
        ))
    }
    return rows
}

private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) == SQLITE_TEXT, let cstr = sqlite3_column_text(stmt, index) else {
        return nil
    }
    let value = String(cString: cstr)
    return value.isEmpty ? nil : value
}

private func columnInt64(_ stmt: OpaquePointer?, _ index: Int32) -> Int64? {
    guard sqlite3_column_type(stmt, index) == SQLITE_INTEGER else { return nil }
    return sqlite3_column_int64(stmt, index)
}

import SQLite3
import Foundation

// Read ~/.codex/state_*.sqlite via the system libsqlite3 C API. 1:1 port of
// src/modes/codex/sqliteReader.ts, minus the loadSql/fs injection seams (TS only injects those
// to avoid reloading the sql.js WASM engine per test / to unit-test fs edge cases in isolation;
// neither cost exists here — libsqlite3 is already loaded process-wide, and discovery's own
// tests exercise this reader against real temp-directory fixtures, same as the TS suite does).
//
// Opens the db READ-ONLY from an in-memory byte copy (sqlite3_deserialize) so the live
// ~/.codex file is never written to or locked — same guarantee the TS comment calls out
// ("sql.js never writes back to disk"). Any open/read/parse failure throws CodexSqliteError;
// CodexDiscovery catches that to degrade to the index-only fallback (§5b, §7.3).

public struct CodexThreadStateRow: Sendable, Equatable {
    public var id: String
    public var cwd: String?
    public var title: String?
    public var preview: String?
    public var updatedAtMs: Int64?
    public var archived: Bool
    public var source: String?
}

public struct CodexThreadStates: Sendable, Equatable {
    // thread id → row (from the `threads` table)
    public var rows: [CodexThreadStateRow]
    // child_thread_id values from thread_spawn_edges: any id here is a sub-agent.
    public var subAgentChildIds: Set<String>
}

// Typed failure so discovery can distinguish "reader failed → fall back to index" from a
// programming error.
public struct CodexSqliteError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public enum CodexSqliteReader {
    // Read thread states from a specific state_*.sqlite file.
    public static func readThreadStatesFromFile(_ dbPath: String) throws -> CodexThreadStates {
        guard let data = FileManager.default.contents(atPath: dbPath) else {
            throw CodexSqliteError("Failed to read Codex state db: \(dbPath)")
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CodexSqliteError("Failed to initialize sqlite3 engine")
        }
        defer { sqlite3_close(db) }

        guard let buf = sqlite3_malloc64(sqlite3_uint64(data.count)) else {
            throw CodexSqliteError("Failed to query Codex state db: \(dbPath)")
        }
        data.withUnsafeBytes { raw in
            _ = memcpy(buf, raw.baseAddress, data.count)
        }
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE) | UInt32(SQLITE_DESERIALIZE_READONLY)
        guard sqlite3_deserialize(
            db, "main", buf.assumingMemoryBound(to: UInt8.self), Int64(data.count), Int64(data.count), flags
        ) == SQLITE_OK else {
            throw CodexSqliteError("Failed to query Codex state db: \(dbPath)")
        }

        guard let rows = queryThreadRows(db), let subAgentChildIds = querySubAgentChildIds(db) else {
            throw CodexSqliteError("Failed to query Codex state db: \(dbPath)")
        }
        return CodexThreadStates(rows: rows, subAgentChildIds: subAgentChildIds)
    }

    // Resolve the highest state_<N>.sqlite in codexHome, then read it. Throws CodexSqliteError
    // when no state db exists so discovery falls back to the index.
    public static func readThreadStates(_ codexHome: String) throws -> CodexThreadStates {
        guard let dbPath = try findStateDatabase(codexHome) else {
            throw CodexSqliteError("No state_<N>.sqlite found in \(codexHome)")
        }
        return try readThreadStatesFromFile(dbPath)
    }

    // Pick the highest N among state_<N>.sqlite; ignores logs_*/goals_*/memories_*.
    public static func findStateDatabase(_ codexHome: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: codexHome) else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: codexHome) else {
            throw CodexSqliteError("Failed to list \(codexHome)")
        }

        var best: (version: Int, name: String)?
        for name in names {
            guard let match = name.wholeMatch(of: #/^state_(\d+)\.sqlite$/#) else { continue }
            guard let version = Int(match.1) else { continue }
            if best == nil || version > best!.version { best = (version, name) }
        }
        guard let best else { return nil }
        return (codexHome as NSString).appendingPathComponent(best.name)
    }
}

// MARK: - SQL helpers

private func queryThreadRows(_ db: OpaquePointer?) -> [CodexThreadStateRow]? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(
        db, "SELECT id, cwd, title, preview, updated_at_ms, archived, source FROM threads", -1, &stmt, nil
    ) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }

    var rows: [CodexThreadStateRow] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let id = columnText(stmt, 0) else { continue }
        rows.append(CodexThreadStateRow(
            id: id,
            cwd: columnText(stmt, 1),
            title: columnText(stmt, 2),
            preview: columnText(stmt, 3),
            updatedAtMs: columnInt64(stmt, 4),
            archived: columnInt64(stmt, 5) == 1,
            source: columnText(stmt, 6)
        ))
    }
    return rows
}

private func querySubAgentChildIds(_ db: OpaquePointer?) -> Set<String>? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT child_thread_id FROM thread_spawn_edges", -1, &stmt, nil) == SQLITE_OK else {
        return nil
    }
    defer { sqlite3_finalize(stmt) }

    var ids: Set<String> = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        if let childId = columnText(stmt, 0) { ids.insert(childId) }
    }
    return ids
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

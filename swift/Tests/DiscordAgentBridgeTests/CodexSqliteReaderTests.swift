import Testing
import Foundation
import SQLite3
@testable import DiscordAgentBridge

// Mirrors src/modes/codex/sqliteReader.test.ts. TS injects a shared sql.js engine to avoid
// reloading its WASM per test; that cost doesn't exist here (libsqlite3 is process-wide), so
// these tests just write real state_*.sqlite fixtures via the C API and read them back through
// the real CodexSqliteReader — same as this suite's discovery-level counterpart.

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dab-sqlite-\(UUID().uuidString)", isDirectory: true)
}

// Builds the fixture db described in sqliteReader.test.ts: one normal user thread, one archived
// thread, one sub-agent thread (also a spawn-edge child), and one exec-source thread.
private func writeFixtureDB(at path: String) {
    var db: OpaquePointer?
    sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, """
        CREATE TABLE threads (
          id TEXT, cwd TEXT, title TEXT, preview TEXT,
          updated_at_ms INTEGER, updated_at TEXT,
          archived INTEGER, sandbox_policy TEXT, approval_mode TEXT,
          source TEXT, thread_source TEXT
        );
        CREATE TABLE thread_spawn_edges (child_thread_id TEXT);
        INSERT INTO threads (id, cwd, title, preview, updated_at_ms, archived, source, thread_source)
          VALUES ('user-1', '/work/user', 'User Title', 'preview text', 2000, 0, 'cli', 'user');
        INSERT INTO threads (id, cwd, title, updated_at_ms, archived, source)
          VALUES ('archived-1', '/work/archived', 'Archived', 1000, 1, 'cli');
        INSERT INTO threads (id, cwd, updated_at_ms, archived, source)
          VALUES ('sub-1', '/work/sub', 1500, 0, '{"subagent":{"parent":"user-1"}}');
        INSERT INTO thread_spawn_edges (child_thread_id) VALUES ('sub-1');
        INSERT INTO threads (id, cwd, updated_at_ms, archived, source)
          VALUES ('exec-1', '/work/exec', 1800, 0, 'exec');
        """, nil, nil, nil)
}

@Suite("CodexSqliteReader")
struct CodexSqliteReaderTests {
    @Test func readThreadStatesFromFileReturnsRowsAndSubAgentChildIds() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("state_1.sqlite").path
        writeFixtureDB(at: dbPath)

        let states = try CodexSqliteReader.readThreadStatesFromFile(dbPath)
        let byId = Dictionary(uniqueKeysWithValues: states.rows.map { ($0.id, $0) })
        #expect(Set(byId.keys) == ["archived-1", "exec-1", "sub-1", "user-1"])

        let user = try #require(byId["user-1"])
        #expect(user.cwd == "/work/user")
        #expect(user.title == "User Title")
        #expect(user.preview == "preview text")
        #expect(user.updatedAtMs == 2000)
        #expect(user.archived == false)
        #expect(user.source == "cli")

        #expect(byId["archived-1"]?.archived == true)
        #expect(byId["sub-1"]?.source == "{\"subagent\":{\"parent\":\"user-1\"}}")
        #expect(byId["exec-1"]?.source == "exec")
        #expect(states.subAgentChildIds == ["sub-1"])
    }

    @Test func readThreadStatesFromFileThrowsOnMissingFile() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: CodexSqliteError.self) {
            try CodexSqliteReader.readThreadStatesFromFile(dir.appendingPathComponent("state_9.sqlite").path)
        }
    }

    @Test func readThreadStatesFromFileThrowsOnCorruptDb() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("state_1.sqlite")
        try Data("not a sqlite database at all".utf8).write(to: bad)
        #expect(throws: CodexSqliteError.self) {
            try CodexSqliteReader.readThreadStatesFromFile(bad.path)
        }
    }

    @Test func findStateDatabasePicksHighestVersionAndIgnoresOtherFamilies() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["state_1.sqlite", "state_2.sqlite", "state_10.sqlite", "logs_99.sqlite", "goals_5.sqlite", "memories_7.sqlite"] {
            writeFixtureDB(at: dir.appendingPathComponent(name).path)
        }
        let picked = try CodexSqliteReader.findStateDatabase(dir.path)
        #expect(picked == dir.appendingPathComponent("state_10.sqlite").path)
    }

    @Test func findStateDatabaseReturnsNilWhenNoneExists() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try CodexSqliteReader.findStateDatabase(dir.path) == nil)
    }

    @Test func findStateDatabaseReturnsNilWhenCodexHomeAbsent() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("dab-does-not-exist-\(UUID().uuidString)")
        #expect(try CodexSqliteReader.findStateDatabase(missing.path) == nil)
    }

    @Test func readThreadStatesResolvesHighestStateDbUnderCodexHome() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeFixtureDB(at: dir.appendingPathComponent("state_1.sqlite").path)
        writeFixtureDB(at: dir.appendingPathComponent("state_3.sqlite").path)
        let states = try CodexSqliteReader.readThreadStates(dir.path)
        #expect(Set(states.rows.map(\.id)) == ["archived-1", "exec-1", "sub-1", "user-1"])
    }

    @Test func readThreadStatesThrowsWhenNoStateDbPresent() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: CodexSqliteError.self) {
            try CodexSqliteReader.readThreadStates(dir.path)
        }
    }
}

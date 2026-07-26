import Testing
import Foundation
import SQLite3
@testable import DiscordAgentBridge

// Mirrors src/modes/grok/discovery.test.ts's buildDbBytes/buildDbBytesFrom fixtures at the
// reader level. TS injects a shared sql.js engine to avoid reloading its WASM per test; that
// cost doesn't exist here (libsqlite3 is process-wide), so these tests just write real
// session_search.sqlite fixtures via the C API and read them back through GrokSqliteReader —
// same approach as CodexSqliteReaderTests.swift.

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dab-groksqlite-\(UUID().uuidString)", isDirectory: true)
}

// Builds the fixture db described in discovery.test.ts's buildDbBytes(): three sessions
// across two cwds, one with an empty title (→ no label).
private func writeFixtureDB(at path: String) {
    var db: OpaquePointer?
    sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, """
        CREATE TABLE session_docs (
          session_id TEXT PRIMARY KEY, cwd TEXT NOT NULL, updated_at INTEGER NOT NULL,
          title TEXT NOT NULL, content TEXT NOT NULL, content_hash TEXT NOT NULL,
          last_indexed_offset INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO session_docs (session_id, cwd, updated_at, title, content, content_hash)
          VALUES ('sess-old', '/work/proj', 1783900000, 'Older session', '', '');
        INSERT INTO session_docs (session_id, cwd, updated_at, title, content, content_hash)
          VALUES ('sess-new', '/work/proj', 1783908336, '', '', '');
        INSERT INTO session_docs (session_id, cwd, updated_at, title, content, content_hash)
          VALUES ('sess-other', '/work/other', 1783908999, 'Other project', '', '');
        """, nil, nil, nil)
}

@Suite("GrokSqliteReader")
struct GrokSqliteReaderTests {
    @Test func readSessionDocsFromFileReturnsRowsNewestFirst() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("session_search.sqlite").path
        writeFixtureDB(at: dbPath)

        let rows = try GrokSqliteReader.readSessionDocsFromFile(dbPath)
        #expect(rows.map(\.sessionId) == ["sess-other", "sess-new", "sess-old"])

        let old = try #require(rows.first { $0.sessionId == "sess-old" })
        #expect(old.cwd == "/work/proj")
        #expect(old.title == "Older session")
        #expect(old.updatedAt == 1783900000)

        let new = try #require(rows.first { $0.sessionId == "sess-new" })
        #expect(new.title == nil) // empty title column → nil, not ""
    }

    @Test func readSessionDocsFromFileThrowsOnMissingFile() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: GrokSqliteError.self) {
            try GrokSqliteReader.readSessionDocsFromFile(dir.appendingPathComponent("session_search.sqlite").path)
        }
    }

    @Test func readSessionDocsFromFileThrowsOnCorruptDb() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("session_search.sqlite")
        try Data("not a sqlite database at all".utf8).write(to: bad)
        #expect(throws: GrokSqliteError.self) {
            try GrokSqliteReader.readSessionDocsFromFile(bad.path)
        }
    }
}

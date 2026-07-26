import Testing
import Foundation
import SQLite3
@testable import DiscordAgentBridge

// Mirrors src/modes/grok/discovery.test.ts (GrokDiscovery.listResumable). Same fixture layout
// (session_search.sqlite under <grokHome>/sessions/) built with real files against a real temp
// dir, same as CodexDiscoveryTests.swift.

private func writeSessionDocsDB(at path: String, rows: [(id: String, cwd: String, updatedAt: Int64, title: String)]) {
    var db: OpaquePointer?
    sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, """
        CREATE TABLE session_docs (
          session_id TEXT PRIMARY KEY, cwd TEXT NOT NULL, updated_at INTEGER NOT NULL,
          title TEXT NOT NULL, content TEXT NOT NULL, content_hash TEXT NOT NULL,
          last_indexed_offset INTEGER NOT NULL DEFAULT 0
        );
        """, nil, nil, nil)
    for row in rows {
        sqlite3_exec(db, """
            INSERT INTO session_docs (session_id, cwd, updated_at, title, content, content_hash)
              VALUES ('\(row.id)', '\(row.cwd)', \(row.updatedAt), '\(row.title)', '', '');
            """, nil, nil, nil)
    }
}

// Fixture matching discovery.test.ts's buildDbBytes(): three sessions across two cwds.
private func defaultRows() -> [(id: String, cwd: String, updatedAt: Int64, title: String)] {
    [
        (id: "sess-old", cwd: "/work/proj", updatedAt: 1783900000, title: "Older session"),
        (id: "sess-new", cwd: "/work/proj", updatedAt: 1783908336, title: ""),
        (id: "sess-other", cwd: "/work/other", updatedAt: 1783908999, title: "Other project"),
    ]
}

private func withGrokHome(
    rows: [(id: String, cwd: String, updatedAt: Int64, title: String)]? = nil,
    corrupt: Bool = false,
    writeDb: Bool = true,
    _ body: (URL) throws -> Void
) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dab-grokhome-\(UUID().uuidString)")
    let sessions = dir.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let dbPath = sessions.appendingPathComponent("session_search.sqlite").path
    if corrupt {
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: dbPath))
    } else if writeDb {
        writeSessionDocsDB(at: dbPath, rows: rows ?? defaultRows())
    }
    try body(dir)
}

@Suite("GrokDiscovery")
struct GrokDiscoveryTests {
    @Test func listsAllSessionsNewestFirstWhenNoCwdFilterGiven() throws {
        try withGrokHome { dir in
            let sessions = GrokDiscovery.listResumable(grokHome: dir.path)
            #expect(sessions.map(\.sessionId) == ["sess-other", "sess-new", "sess-old"])
        }
    }

    @Test func filtersToGivenCwdAndPreservesRecencyOrder() throws {
        try withGrokHome { dir in
            let sessions = GrokDiscovery.listResumable(grokHome: dir.path, cwd: "/work/proj")
            #expect(sessions.map(\.sessionId) == ["sess-new", "sess-old"])
            #expect(sessions.allSatisfy { $0.cwd == "/work/proj" })
        }
    }

    @Test func mapsTitleToLabelAndUpdatedAtToIsoString() throws {
        try withGrokHome { dir in
            let sessions = GrokDiscovery.listResumable(grokHome: dir.path, cwd: "/work/proj")
            let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
            #expect(byId["sess-old"]?.label == "Older session")
            #expect(byId["sess-new"]?.label == nil) // empty title → no label
            #expect(byId["sess-new"]?.updatedAt == "2026-07-13T02:05:36.000Z")
        }
    }

    @Test func matchesWhenStoredCwdHasTrailingSlashQueryLacks() throws {
        let rows = [(id: "sess-slash", cwd: "/work/proj/", updatedAt: Int64(1783908336), title: "Slashed")]
        try withGrokHome(rows: rows) { dir in
            let sessions = GrokDiscovery.listResumable(grokHome: dir.path, cwd: "/work/proj")
            #expect(sessions.map(\.sessionId) == ["sess-slash"])
        }
    }

    @Test func matchesWhenQueryCwdHasTrailingSlashStoredCwdLacks() throws {
        let rows = [(id: "sess-noslash", cwd: "/work/proj", updatedAt: Int64(1783908336), title: "NoSlash")]
        try withGrokHome(rows: rows) { dir in
            let sessions = GrokDiscovery.listResumable(grokHome: dir.path, cwd: "/work/proj/")
            #expect(sessions.map(\.sessionId) == ["sess-noslash"])
        }
    }

    // Stored cwd + query cwd point at the same directory through a symlink (the /Volumes↔/private
    // case in the wild) — must still match via realpathOrResolve, not a literal string compare.
    @Test func matchesAcrossSymlinkedCwdDifference() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dab-groklink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let realDir = base.appendingPathComponent("realproj")
        let linkDir = base.appendingPathComponent("linkproj")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let rows = [(id: "sess-link", cwd: realDir.path, updatedAt: Int64(1783908336), title: "Linked")]
        try withGrokHome(rows: rows) { dir in
            let sessions = GrokDiscovery.listResumable(grokHome: dir.path, cwd: linkDir.path)
            #expect(sessions.map(\.sessionId) == ["sess-link"])
        }
    }

    @Test func excludesGenuinelyDifferentCwdAfterNormalization() throws {
        try withGrokHome { dir in
            #expect(GrokDiscovery.listResumable(grokHome: dir.path, cwd: "/work/nomatch").isEmpty)
        }
    }

    @Test func returnsEmptyListWhenDbFileAbsent() throws {
        try withGrokHome(writeDb: false) { dir in
            #expect(GrokDiscovery.listResumable(grokHome: dir.path).isEmpty)
        }
    }

    @Test func returnsEmptyListWhenDbCorrupt() throws {
        try withGrokHome(corrupt: true) { dir in
            #expect(GrokDiscovery.listResumable(grokHome: dir.path).isEmpty)
        }
    }
}

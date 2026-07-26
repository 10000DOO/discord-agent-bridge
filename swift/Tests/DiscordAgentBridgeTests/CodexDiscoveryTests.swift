import Testing
import Foundation
import SQLite3
@testable import DiscordAgentBridge

// Mirrors src/modes/codex/discovery.test.ts. Same ~/.codex fixture layout (session_index.jsonl +
// rollout-*.jsonl + state_2.sqlite), built with real files against a real temp dir (TS's own
// suite does the same despite its injectable seams — see CodexSqliteReaderTests.swift header).

private enum ID {
    static let user1 = "11111111-1111-1111-1111-111111111111"
    static let user2 = "22222222-2222-2222-2222-222222222222"
    static let archived = "33333333-3333-3333-3333-333333333333"
    static let sub = "44444444-4444-4444-4444-444444444444"
    static let exec = "55555555-5555-5555-5555-555555555555"
}

private func writeStateDB(at path: String) {
    var db: OpaquePointer?
    sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    defer { sqlite3_close(db) }
    sqlite3_exec(db, """
        CREATE TABLE threads (
          id TEXT, cwd TEXT, title TEXT, preview TEXT,
          updated_at_ms INTEGER, archived INTEGER, source TEXT
        );
        CREATE TABLE thread_spawn_edges (child_thread_id TEXT);
        INSERT INTO threads (id, cwd, title, preview, updated_at_ms, archived, source)
          VALUES ('\(ID.user1)', '/work/user-1', 'From SQLite', 'preview', 3000, 0, 'cli');
        INSERT INTO threads (id, cwd, preview, updated_at_ms, archived, source)
          VALUES ('\(ID.user2)', '/work/user-2', 'Preview label', 2500, 0, 'vscode');
        INSERT INTO threads (id, cwd, title, updated_at_ms, archived, source)
          VALUES ('\(ID.archived)', '/work/arch', 'Archived', 2000, 1, 'cli');
        INSERT INTO threads (id, cwd, updated_at_ms, archived, source)
          VALUES ('\(ID.sub)', '/work/sub', 1900, 0, '{"subagent":{}}');
        INSERT INTO thread_spawn_edges (child_thread_id) VALUES ('\(ID.sub)');
        INSERT INTO threads (id, cwd, updated_at_ms, archived, source)
          VALUES ('\(ID.exec)', '/work/exec', 1800, 0, 'exec');
        """, nil, nil, nil)
}

private func indexLine(_ id: String, _ threadName: String, _ updatedAt: String) -> String {
    #"{"id":"\#(id)","thread_name":"\#(threadName)","updated_at":"\#(updatedAt)"}"#
}

private func rolloutMeta(_ id: String, _ cwd: String) -> String {
    #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","cli_version":"0.142.4"}}"#
}

private func makeCodexHome(
    _ dir: URL,
    writeState: Bool = false,
    corruptState: Bool = false,
    archivedIds: [String] = []
) throws {
    let lines = [
        indexLine(ID.user1, "user-1 name", "2026-07-01T10:00:00Z"),
        indexLine(ID.user2, "user-2 name", "2026-07-01T09:00:00Z"),
        indexLine(ID.archived, "archived name", "2026-07-01T08:00:00Z"),
        indexLine(ID.sub, "sub name", "2026-07-01T07:00:00Z"),
        indexLine(ID.exec, "exec name", "2026-07-01T06:00:00Z"),
    ]
    try (lines.joined(separator: "\n") + "\n").write(
        to: dir.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8
    )

    let day = dir.appendingPathComponent("sessions/2026/07/01", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    func writeRollout(_ uuid: String, _ cwd: String) throws {
        let content = rolloutMeta(uuid, cwd) + "\n" + #"{"type":"response_item"}"# + "\n"
        try content.write(
            to: day.appendingPathComponent("rollout-2026-07-01T10-00-00-\(uuid).jsonl"),
            atomically: true, encoding: .utf8
        )
    }
    try writeRollout(ID.user1, "/rollout/user-1")
    try writeRollout(ID.user2, "/rollout/user-2")

    let statePath = dir.appendingPathComponent("state_2.sqlite").path
    if corruptState {
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: statePath))
    } else if writeState {
        writeStateDB(at: statePath)
    }

    if !archivedIds.isEmpty {
        let archivedDay = dir.appendingPathComponent("archived_sessions/2026/07/01", isDirectory: true)
        try FileManager.default.createDirectory(at: archivedDay, withIntermediateDirectories: true)
        for id in archivedIds {
            let content = rolloutMeta(id, "/archived") + "\n"
            try content.write(
                to: archivedDay.appendingPathComponent("rollout-2026-07-01T05-00-00-\(id).jsonl"),
                atomically: true, encoding: .utf8
            )
        }
    }
}

private func withCodexHome(
    writeState: Bool = false,
    corruptState: Bool = false,
    archivedIds: [String] = [],
    _ body: (URL) throws -> Void
) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dab-codexhome-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try makeCodexHome(dir, writeState: writeState, corruptState: corruptState, archivedIds: archivedIds)
    try body(dir)
}

@Suite("CodexDiscovery")
struct CodexDiscoveryTests {
    @Test func listsOnlyResumableUserThreadsSortedByRecency() throws {
        try withCodexHome(writeState: true) { dir in
            let sessions = CodexDiscovery.listResumable(codexHome: dir.path)
            // archived (archived), sub (sub-agent), exec (exec source) excluded.
            #expect(sessions.map(\.sessionId) == [ID.user1, ID.user2])
        }
    }

    @Test func labelsFromSqliteTitleThenPreviewCwdFromSqlite() throws {
        try withCodexHome(writeState: true) { dir in
            let sessions = CodexDiscovery.listResumable(codexHome: dir.path)
            let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
            #expect(byId[ID.user1]?.label == "From SQLite")
            #expect(byId[ID.user1]?.cwd == "/work/user-1")
            #expect(byId[ID.user1]?.updatedAt == "2026-07-01T10:00:00Z")
            #expect(byId[ID.user2]?.label == "Preview label")
        }
    }

    @Test func includesSubAgentsWhenIncludeSubAgentsIsSet() throws {
        try withCodexHome(writeState: true) { dir in
            let sessions = CodexDiscovery.listResumable(codexHome: dir.path, includeSubAgents: true)
            let ids = sessions.map(\.sessionId)
            #expect(ids.contains(ID.sub))
            #expect(!ids.contains(ID.archived))
            #expect(!ids.contains(ID.exec))
        }
    }

    @Test func fallsBackToIndexAndWarnsWhenDbUnreadable() throws {
        try withCodexHome(corruptState: true) { dir in
            let sessions = CodexDiscovery.listResumable(codexHome: dir.path)
            #expect(Set(sessions.map(\.sessionId)) == [ID.user1, ID.user2, ID.archived, ID.sub, ID.exec])
            let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
            #expect(byId[ID.user1]?.cwd == "/rollout/user-1")
            #expect(byId[ID.user1]?.label == "user-1 name")
        }
    }

    @Test func fallsBackWhenNoStateDbExistsAtAll() throws {
        try withCodexHome { dir in
            let sessions = CodexDiscovery.listResumable(codexHome: dir.path)
            #expect(sessions.count == 5)
        }
    }

    @Test func stillExcludesArchivedSessionsDirIdsInIndexOnlyFallback() throws {
        try withCodexHome(corruptState: true, archivedIds: [ID.archived]) { dir in
            let ids = CodexDiscovery.listResumable(codexHome: dir.path).map(\.sessionId)
            #expect(!ids.contains(ID.archived))
            #expect(Set(ids) == [ID.user1, ID.user2, ID.sub, ID.exec])
        }
    }

    @Test func toleratesMissingArchivedSessionsDirInFallback() throws {
        try withCodexHome(corruptState: true) { dir in
            #expect(CodexDiscovery.listResumable(codexHome: dir.path).count == 5)
        }
    }

    @Test func excludesIndexSessionWithNoThreadsRow() throws {
        try withCodexHome(writeState: true) { dir in
            let ghost = "99999999-9999-9999-9999-999999999999"
            let line = indexLine(ghost, "ghost name", "2026-07-01T11:00:00Z") + "\n"
            let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("session_index.jsonl"))
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try handle.close()

            let sessions = CodexDiscovery.listResumable(codexHome: dir.path)
            #expect(!sessions.map(\.sessionId).contains(ghost))
            #expect(sessions.map(\.sessionId) == [ID.user1, ID.user2])
        }
    }

    @Test func returnsEmptyListWhenNoSessionIndexJsonl() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dab-codexhome-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(CodexDiscovery.listResumable(codexHome: dir.path).isEmpty)
    }
}

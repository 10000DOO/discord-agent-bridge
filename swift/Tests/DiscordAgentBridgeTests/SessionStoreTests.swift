import Testing
import Foundation
@testable import DiscordAgentBridge

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-store-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("swift-state.json", isDirectory: false)
}

private func sample(_ backend: Backend, _ cwd: String) -> PersistedSession {
    PersistedSession(backend: backend, backendSessionId: "bk-\(cwd)", cwd: cwd, guildId: "g",
                     ownerId: "owner", model: "m", effort: "high", permMode: "plan", updatedAt: "2026-07-24T00:00:00Z")
}

@Suite("SessionStore")
struct SessionStoreTests {
    @Test func roundtripAcrossInstances() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let a = SessionStore(fileURL: url)
        try await a.upsert(channelId: "c1", sample(.codex, "/ws1"))
        try await a.upsert(channelId: "c2", sample(.grok, "/ws2"))

        let b = SessionStore(fileURL: url)          // fresh instance, same file
        await b.load()
        #expect(await b.binding(channelId: "c1") == sample(.codex, "/ws1"))
        #expect(await b.binding(channelId: "c2") == sample(.grok, "/ws2"))
        #expect(await b.all().count == 2)
    }

    @Test func corruptFileLoadsEmpty() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("}{ not json \u{00}".utf8).write(to: url)

        let s = SessionStore(fileURL: url)
        await s.load()                               // must not throw
        #expect(await s.all().isEmpty)
    }

    @Test func missingFileLoadsEmpty() async {
        let s = SessionStore(fileURL: tempStoreURL())
        await s.load()
        #expect(await s.all().isEmpty)
    }

    // F3: mutation re-reads the file, so a key written out-of-band by another writer survives.
    @Test func loadMergeSavePreservesOtherKeys() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        try await s.upsert(channelId: "c1", sample(.claude, "/ws1"))

        // Simulate a concurrent writer adding c2 directly to the file.
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var channels = raw["channels"] as! [String: Any]
        channels["c2"] = [
            "backend": "grok", "cwd": "/ws2", "guildId": "g", "updatedAt": "2026-07-24T00:00:00Z",
        ]
        raw["channels"] = channels
        try JSONSerialization.data(withJSONObject: raw).write(to: url)

        // Re-upsert c1 → must NOT clobber c2.
        try await s.upsert(channelId: "c1", sample(.claude, "/ws1b"))

        let reloaded = SessionStore(fileURL: url)
        await reloaded.load()
        #expect(await reloaded.binding(channelId: "c1")?.cwd == "/ws1b")
        #expect(await reloaded.binding(channelId: "c2")?.backend == .grok)   // survived
    }

    @Test func atomicWriteProducesValidVersionedFile() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        try await s.upsert(channelId: "c1", sample(.codex, "/ws"))

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(obj["version"] as? Int == 1)
        #expect((obj["channels"] as? [String: Any])?["c1"] != nil)
        // No leftover tmp sibling after a successful write.
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    @Test func permissionsAre0600() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        try await s.upsert(channelId: "c1", sample(.grok, "/ws"))

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func removeDeletesKeyAndPersists() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        try await s.upsert(channelId: "c1", sample(.codex, "/ws1"))
        try await s.upsert(channelId: "c2", sample(.grok, "/ws2"))
        try await s.remove(channelId: "c1")

        let reloaded = SessionStore(fileURL: url)
        await reloaded.load()
        #expect(await reloaded.binding(channelId: "c1") == nil)
        #expect(await reloaded.binding(channelId: "c2") != nil)
    }
}

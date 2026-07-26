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
        // upsert fills createdAt from updatedAt when absent.
        var e1 = sample(.codex, "/ws1"); e1.createdAt = e1.updatedAt
        var e2 = sample(.grok, "/ws2"); e2.createdAt = e2.updatedAt
        #expect(await b.binding(channelId: "c1") == e1)
        #expect(await b.binding(channelId: "c2") == e2)
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
        #expect(obj["version"] as? Int == STATE_VERSION)
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

    // MARK: - W15-b

    @Test func migratesV1ToV2AndDefaultsArchived() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Pre-W15-b v1 file: bare channelId key, no archived field.
        let v1: [String: Any] = [
            "version": 1,
            "channels": [
                "c1": [
                    "backend": "claude",
                    "cwd": "/ws",
                    "guildId": "g9",
                    "updatedAt": "2026-01-01T00:00:00Z",
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: v1).write(to: url)

        let s = SessionStore(fileURL: url)
        await s.load()
        #expect(await s.binding(channelId: "c1")?.backend == .claude)
        #expect(await s.binding(channelId: "c1")?.archived == false)
        #expect(await s.binding(channelId: "c1")?.guildId == "g9")

        // Next write stamps STATE_VERSION.
        try await s.upsert(channelId: "c1", sample(.claude, "/ws2"))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(obj["version"] as? Int == STATE_VERSION)
    }

    @Test func markArchivedSoftDeletesWithoutRemoving() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        try await s.upsert(channelId: "c1", sample(.codex, "/ws"))
        let marked = try await s.markArchived(channelId: "c1")
        #expect(marked?.archived == true)
        #expect(await s.binding(channelId: "c1")?.archived == true)
        #expect(await s.all().count == 1)
        #expect(await s.active().isEmpty)

        #expect(try await s.markArchived(channelId: "missing") == nil)

        let reloaded = SessionStore(fileURL: url)
        await reloaded.load()
        #expect(await reloaded.binding(channelId: "c1")?.archived == true)
        #expect(await reloaded.active().isEmpty)
    }

    @Test func autoUpdateMetaDefaultsAndPersists() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        await s.load()
        #expect(await s.getUpdateMeta() == .empty)

        try await s.setUpdateMeta(AutoUpdateMetaPatch(lastCheckAt: 42))
        #expect(await s.getUpdateMeta().lastCheckAt == 42)
        #expect(await s.getUpdateMeta().dismissedVersion == nil)

        try await s.setUpdateMeta(AutoUpdateMetaPatch(dismissedVersion: "1.2.3"))
        #expect(await s.getUpdateMeta().lastCheckAt == 42)
        #expect(await s.getUpdateMeta().dismissedVersion == "1.2.3")

        // Channel mutation must not clobber autoUpdate.
        try await s.upsert(channelId: "c1", sample(.claude, "/ws"))
        #expect(await s.getUpdateMeta().dismissedVersion == "1.2.3")

        let reloaded = SessionStore(fileURL: url)
        await reloaded.load()
        #expect(await reloaded.getUpdateMeta().lastCheckAt == 42)
        #expect(await reloaded.getUpdateMeta().dismissedVersion == "1.2.3")
        #expect(await reloaded.binding(channelId: "c1")?.backend == .claude)
    }

    @Test func autoUpdateAbsentInOldFileDefaults() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixture: [String: Any] = [
            "version": 2,
            "channels": [:] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: fixture).write(to: url)
        let s = SessionStore(fileURL: url)
        await s.load()
        #expect(await s.getUpdateMeta() == .empty)
    }

    @Test func normalizeModeIdOnLoadForBackendAliases() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fixture: [String: Any] = [
            "version": 2,
            "channels": [
                "c-grok": [
                    "backend": "grok", "cwd": "/a", "guildId": "g", "updatedAt": "t", "archived": false,
                ] as [String: Any],
                "c-agent": [
                    "backend": "grok-agent", "cwd": "/b", "guildId": "g", "updatedAt": "t", "archived": false,
                ] as [String: Any],
                "c-build": [
                    "backend": "grok-build", "cwd": "/c", "guildId": "g", "updatedAt": "t", "archived": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: fixture).write(to: url)

        let s = SessionStore(fileURL: url)
        await s.load()
        #expect(await s.binding(channelId: "c-grok")?.backend == .grok)
        #expect(await s.binding(channelId: "c-agent")?.backend == .grok)
        #expect(await s.binding(channelId: "c-build")?.backend == .grok)
    }

    @Test func optionalBindingFieldsRoundTrip() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        let record = PersistedSession(
            backend: .claude,
            cwd: "/ws",
            guildId: "g1",
            permissionProfile: "proj-prof",
            projectAuth: ProjectAuth(allowedRoleIds: ["r1"], allowedUserIds: ["u1"]),
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-02T00:00:00Z",
            archived: false
        )
        try await s.upsert(channelId: "c1", record)

        let reloaded = SessionStore(fileURL: url)
        await reloaded.load()
        let got = await reloaded.binding(channelId: "c1")
        #expect(got?.permissionProfile == "proj-prof")
        #expect(got?.projectAuth == ProjectAuth(allowedRoleIds: ["r1"], allowedUserIds: ["u1"]))
        #expect(got?.createdAt == "2026-01-01T00:00:00Z")
    }

    @Test func upsertPreservesCreatedAt() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        try await s.upsert(
            channelId: "c1",
            PersistedSession(backend: .claude, cwd: "/a", guildId: "g",
                             createdAt: "CREATED", updatedAt: "T1")
        )
        try await s.upsert(
            channelId: "c1",
            PersistedSession(backend: .claude, cwd: "/b", guildId: "g", updatedAt: "T2")
        )
        #expect(await s.binding(channelId: "c1")?.createdAt == "CREATED")
        #expect(await s.binding(channelId: "c1")?.cwd == "/b")
    }

    /// G-P0-05: turn-time persistSession must not drop binding-resident projectAuth.
    @Test func persistSessionCarriesProjectAuth() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        let acl = ProjectAuth(allowedRoleIds: ["r1"], allowedUserIds: ["u1"])
        try await s.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude,
                cwd: "/ws",
                guildId: "g1",
                permissionProfile: "prof",
                projectAuth: acl,
                createdAt: "C0",
                updatedAt: "T0"
            )
        )
        await persistSession(
            store: s,
            backend: .claude,
            channelId: "c1",
            guildId: "g1",
            ownerId: "u1",
            cwd: "/ws",
            model: "m",
            effort: "high",
            permMode: "default",
            backendSessionId: "sess-1"
        )
        let got = await s.binding(channelId: "c1")
        #expect(got?.projectAuth == acl)
        #expect(got?.permissionProfile == "prof")
        #expect(got?.backendSessionId == "sess-1")
        #expect(got?.model == "m")
        #expect(got?.createdAt == "C0")
    }
}

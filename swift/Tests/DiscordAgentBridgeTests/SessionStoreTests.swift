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
        let e1 = await a.binding(channelId: "c1")
        let e2 = await a.binding(channelId: "c2")

        let b = SessionStore(fileURL: url)          // fresh instance, same file
        await b.load()
        // Upsert normalizes createdAt and persists the lifecycle generation, so use the actual
        // durable source records instead of constructing fresh random-generation fixtures.
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

    @Test func corruptFileIsBackedUpBeforeFreshEmptyStoreIsCreated() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("}{ not json".utf8)
        try corrupt.write(to: url)

        let s = SessionStore(fileURL: url)
        await s.load()

        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let backupName = try #require(names.first { $0.hasPrefix("swift-state.json.corrupt-") })
        #expect(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(backupName)) == corrupt)
        let fresh = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(fresh?["version"] as? Int == STATE_VERSION)
        #expect((fresh?["channels"] as? [String: Any])?.isEmpty == true)
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

    // WO-1 (redmine-issue-session-start.md): guild-scoped active() must only return
    // non-archived bindings for the requested guild.
    @Test func activeFiltersByGuildAndExcludesArchived() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        try await s.upsert(channelId: "c1", PersistedSession(
            backend: .claude, cwd: "/ws1", guildId: "g1", updatedAt: "T0"
        ))
        try await s.upsert(channelId: "c2", PersistedSession(
            backend: .codex, cwd: "/ws2", guildId: "g1", updatedAt: "T0"
        ))
        try await s.upsert(channelId: "c3", PersistedSession(
            backend: .grok, cwd: "/ws3", guildId: "g2", updatedAt: "T0"
        ))
        _ = try await s.markArchived(channelId: "c2")   // same guild (g1) as c1, but archived

        #expect(await s.active(guildId: "g1").keys.sorted() == ["c1"])
        #expect(await s.active(guildId: "g2").keys.sorted() == ["c3"])
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

    @Test func pendingRestartVersionSetAndClearRoundTrips() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        await s.load()
        #expect(await s.getUpdateMeta().pendingRestartVersion == nil)

        try await s.setUpdateMeta(AutoUpdateMetaPatch(pendingRestartVersion: "1.1.0"))
        #expect(await s.getUpdateMeta().pendingRestartVersion == "1.1.0")

        let reloaded = SessionStore(fileURL: url)
        await reloaded.load()
        #expect(await reloaded.getUpdateMeta().pendingRestartVersion == "1.1.0")

        try await s.setUpdateMeta(AutoUpdateMetaPatch(clearPendingRestart: true))
        #expect(await s.getUpdateMeta().pendingRestartVersion == nil)

        let reloadedAfterClear = SessionStore(fileURL: url)
        await reloadedAfterClear.load()
        #expect(await reloadedAfterClear.getUpdateMeta().pendingRestartVersion == nil)
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

    // H7: an unregistered/corrupt backend value must not silently become `.claude`, and must not
    // block the rest of the store from loading — only that one binding is skipped.
    @Test func unknownBackendSkipsOnlyThatBindingKeepsOthers() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fixture: [String: Any] = [
            "version": 2,
            "channels": [
                "c-good": [
                    "backend": "claude", "cwd": "/a", "guildId": "g", "updatedAt": "t", "archived": false,
                ] as [String: Any],
                "c-bad": [
                    "backend": "future-backend", "cwd": "/b", "guildId": "g", "updatedAt": "t", "archived": false,
                ] as [String: Any],
                "c-good2": [
                    "backend": "codex", "cwd": "/c", "guildId": "g", "updatedAt": "t", "archived": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: fixture).write(to: url)

        let s = SessionStore(fileURL: url)
        await s.load()
        #expect(await s.binding(channelId: "c-good")?.backend == .claude)
        #expect(await s.binding(channelId: "c-good2")?.backend == .codex)
        #expect(await s.binding(channelId: "c-bad") == nil)   // skipped, NOT silently mapped to .claude
        #expect(await s.all().count == 2)
    }

    @Test func backendFromModeReturnsNilForUnknownValue() {
        #expect(PersistedSession.backend(fromMode: "future-backend") == nil)
        #expect(PersistedSession.backend(fromMode: "claude") == .claude)
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

    // MARK: - C16 (preset draft persistence)

    @Test func presetDraftPersistsAcrossInstances() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        let draft = PresetDraft(backend: "codex", model: "o3", effort: "high", permMode: "plan")
        try await s.setPresetDraft(draft, key: "g1:c1")

        let reloaded = SessionStore(fileURL: url)
        await reloaded.load()
        #expect(await reloaded.presetDraft(key: "g1:c1") == draft)
    }

    @Test func presetDraftsAcrossChannelsDontMix() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        let d1 = PresetDraft(backend: "claude", model: "opus")
        let d2 = PresetDraft(backend: "grok", model: "grok-4")
        try await s.setPresetDraft(d1, key: "g1:c1")
        try await s.setPresetDraft(d2, key: "g1:c2")

        #expect(await s.presetDraft(key: "g1:c1") == d1)
        #expect(await s.presetDraft(key: "g1:c2") == d2)

        let reloaded = SessionStore(fileURL: url)
        await reloaded.load()
        #expect(await reloaded.presetDraft(key: "g1:c1") == d1)
        #expect(await reloaded.presetDraft(key: "g1:c2") == d2)
    }

    @Test func removePresetDraftDeletesOnlyThatKey() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        try await s.setPresetDraft(PresetDraft(backend: "claude"), key: "g1:c1")
        try await s.setPresetDraft(PresetDraft(backend: "grok"), key: "g1:c2")
        try await s.removePresetDraft(key: "g1:c1")

        #expect(await s.presetDraft(key: "g1:c1") == nil)
        #expect(await s.presetDraft(key: "g1:c2") != nil)
    }

    /// Channel binding mutation (`mutate()`) must not clobber presetDrafts written earlier.
    @Test func channelMutationDoesNotClobberPresetDrafts() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        let draft = PresetDraft(backend: "codex", model: "o3")
        try await s.setPresetDraft(draft, key: "g1:c1")
        try await s.upsert(channelId: "c1", sample(.claude, "/ws"))

        #expect(await s.presetDraft(key: "g1:c1") == draft)

        let reloaded = SessionStore(fileURL: url)
        await reloaded.load()
        #expect(await reloaded.presetDraft(key: "g1:c1") == draft)
        #expect(await reloaded.binding(channelId: "c1")?.backend == .claude)
    }

    /// `setUpdateMeta` must not clobber presetDrafts, and vice versa.
    @Test func updateMetaMutationDoesNotClobberPresetDrafts() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let s = SessionStore(fileURL: url)
        let draft = PresetDraft(backend: "grok")
        try await s.setPresetDraft(draft, key: "g1:c1")
        try await s.setUpdateMeta(AutoUpdateMetaPatch(lastCheckAt: 99))

        #expect(await s.presetDraft(key: "g1:c1") == draft)
        #expect(await s.getUpdateMeta().lastCheckAt == 99)

        // And the reverse: a preset-draft write must not clobber autoUpdate.
        try await s.setPresetDraft(PresetDraft(backend: "codex"), key: "g1:c2")
        #expect(await s.getUpdateMeta().lastCheckAt == 99)
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
                updatedAt: "T0",
                projectSettingSourcesOnly: true
            )
        )
        let generation = await s.binding(channelId: "c1")!.lifecycleGeneration
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
            backendSessionId: "sess-1",
            lifecycleGeneration: generation
        )
        let got = await s.binding(channelId: "c1")
        #expect(got?.projectAuth == acl)
        #expect(got?.permissionProfile == "prof")
        #expect(got?.projectSettingSourcesOnly == true)
        #expect(got?.backendSessionId == "sess-1")
        #expect(got?.model == "m")
        #expect(got?.createdAt == "C0")
    }

    @Test func persistSessionKeepsBindingWorkspaceOverBridgeFallback() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = SessionStore(fileURL: url)
        try await s.upsert(
            channelId: "c1",
            PersistedSession(backend: .claude, cwd: "/wizard-workspace", guildId: "g1", updatedAt: "T0")
        )

        let generation = await s.binding(channelId: "c1")!.lifecycleGeneration
        await persistSession(
            store: s, backend: .claude, channelId: "c1", guildId: "g1", ownerId: "u1",
            cwd: "/bridge-fallback", model: nil, effort: nil, permMode: nil, backendSessionId: "new-id",
            lifecycleGeneration: generation
        )

        #expect(await s.binding(channelId: "c1")?.cwd == "/wizard-workspace")
        #expect(await s.binding(channelId: "c1")?.backendSessionId == "new-id")
    }

    @Test func latePersistCallbackCannotOverwriteReconfiguredOrArchivedBinding() async throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = SessionStore(fileURL: url)
        let reconfigured = PersistedSession(
            backend: .claude, backendSessionId: "claude-current", cwd: "/current", guildId: "g1",
            lifecycleGeneration: "current-generation", updatedAt: "T0"
        )
        try await s.upsert(channelId: "changed", reconfigured)
        let archived = PersistedSession(
            backend: .claude, backendSessionId: nil, cwd: "/archived", guildId: "g1", updatedAt: "T0", archived: true
        )
        try await s.upsert(channelId: "archived", archived)

        // upsert normalizes createdAt, so compare against the durable records that the stale
        // callback is required to preserve rather than the pre-upsert fixture values.
        let storedReconfigured = await s.binding(channelId: "changed")
        let storedArchived = await s.binding(channelId: "archived")
        #expect(storedReconfigured != nil)
        #expect(storedArchived != nil)

        await persistSession(
            store: s, backend: .claude, channelId: "changed", guildId: "g1", ownerId: "u1",
            cwd: "/stale", model: "old", effort: nil, permMode: nil, backendSessionId: "late-claude-id",
            lifecycleGeneration: "stale-generation"
        )
        await persistSession(
            store: s, backend: .claude, channelId: "archived", guildId: "g1", ownerId: "u1",
            cwd: "/stale", model: "old", effort: nil, permMode: nil, backendSessionId: "late-claude-id",
            lifecycleGeneration: "stale-generation"
        )

        #expect(await s.binding(channelId: "changed") == storedReconfigured)
        #expect(await s.binding(channelId: "archived") == storedArchived)
    }
}

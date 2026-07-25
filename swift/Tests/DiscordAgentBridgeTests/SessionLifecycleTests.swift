import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("SessionLifecycle")
struct SessionLifecycleTests {
    private func tempAudit() -> AuditLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-audit-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit.jsonl", isDirectory: false)
        return AuditLog(fileURL: url, now: { "T" })
    }

    @Test func stopChannelAlwaysStopsAllThreeBridges() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let stopped = LockedBox<[String]>([])
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude))
        try await store.upsert(
            channelId: "c1",
            PersistedSession(backend: .claude, backendSessionId: "B", cwd: "/x", guildId: "g", updatedAt: "t")
        )
        let life = SessionLifecycle(
            registry: reg,
            store: store,
            audit: tempAudit(),
            stopClaude: { ch in stopped.withLock { $0.append("claude:\(ch)") } },
            stopCodex: { ch in stopped.withLock { $0.append("codex:\(ch)") } },
            stopGrok: { ch in stopped.withLock { $0.append("grok:\(ch)") } },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false }
        )
        let did = await life.stopChannel(channelId: "c1", actorId: "u1", guildId: "g")
        #expect(did == true)
        #expect(await reg.binding(channelId: "c1") == nil)
        #expect(await store.binding(channelId: "c1") == nil)
        // RV: always all three, not just resolveBackend(.claude).
        #expect(stopped.withLock { $0 } == ["claude:c1", "codex:c1", "grok:c1"])
    }

    @Test func stopChannelNoBindingIsIdempotent() async {
        let stopped = LockedBox(0)
        let life = SessionLifecycle(
            registry: SessionRegistry(),
            store: freshTempStore(),
            audit: tempAudit(),
            stopClaude: { _ in stopped.withLock { $0 += 1 } },
            stopCodex: { _ in stopped.withLock { $0 += 1 } },
            stopGrok: { _ in stopped.withLock { $0 += 1 } },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false }
        )
        // Still calls all three stops (prefix-only leak path) but reports false (no binding).
        #expect(await life.stopChannel(channelId: "none", actorId: "u", guildId: "g") == false)
        #expect(stopped.withLock { $0 } == 3)
    }

    @Test func interruptTriesAllBridgesDoesNotUnbind() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        await reg.bind(channelId: "c1", SessionConfig(backend: .codex))
        try await store.upsert(
            channelId: "c1",
            PersistedSession(backend: .codex, backendSessionId: "t1", cwd: "/x", guildId: "g", updatedAt: "t")
        )
        let interrupted = LockedBox<[String]>([])
        let life = SessionLifecycle(
            registry: reg,
            store: store,
            audit: tempAudit(),
            stopClaude: { _ in },
            stopCodex: { _ in },
            stopGrok: { _ in },
            interruptClaude: { ch in interrupted.withLock { $0.append("claude:\(ch)") }; return false },
            interruptCodex: { ch in interrupted.withLock { $0.append("codex:\(ch)") }; return true },
            interruptGrok: { ch in interrupted.withLock { $0.append("grok:\(ch)") }; return false }
        )
        #expect(await life.interruptChannel(channelId: "c1", actorId: "u", guildId: "g") == true)
        #expect(interrupted.withLock { $0 } == ["claude:c1", "codex:c1", "grok:c1"])
        #expect(await reg.binding(channelId: "c1")?.backend == .codex)
        #expect(await store.binding(channelId: "c1")?.backendSessionId == "t1")
    }

    @Test func stopAllEnumeratesRegistryAndStore() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        await reg.bind(channelId: "a", SessionConfig(backend: .claude))
        try await store.upsert(
            channelId: "b",
            PersistedSession(backend: .grok, cwd: "/x", guildId: "g-store", updatedAt: "t")
        )
        let stopped = LockedBox<Set<String>>([])
        let life = SessionLifecycle(
            registry: reg,
            store: store,
            audit: tempAudit(),
            stopClaude: { ch in stopped.withLock { _ = $0.insert("claude:\(ch)") } },
            stopCodex: { ch in stopped.withLock { _ = $0.insert("codex:\(ch)") } },
            stopGrok: { ch in stopped.withLock { _ = $0.insert("grok:\(ch)") } },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false }
        )
        let n = await life.stopAll(actorId: "admin", guildId: "g-default")
        #expect(n == 2)
        // Each channel gets all three bridge stops.
        #expect(stopped.withLock { $0 }.contains("claude:a"))
        #expect(stopped.withLock { $0 }.contains("codex:a"))
        #expect(stopped.withLock { $0 }.contains("grok:a"))
        #expect(stopped.withLock { $0 }.contains("claude:b"))
        #expect(stopped.withLock { $0 }.contains("codex:b"))
        #expect(stopped.withLock { $0 }.contains("grok:b"))
        #expect(await reg.list().isEmpty)
        #expect(await store.all().isEmpty)
    }

    @Test func stopAllSkipsArchivedStoreBindings() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "live",
            PersistedSession(backend: .claude, cwd: "/x", guildId: "g", updatedAt: "t")
        )
        try await store.upsert(
            channelId: "arch",
            PersistedSession(backend: .grok, cwd: "/y", guildId: "g", updatedAt: "t", archived: true)
        )
        let stopped = LockedBox<Set<String>>([])
        let life = SessionLifecycle(
            registry: reg,
            store: store,
            audit: tempAudit(),
            stopClaude: { ch in stopped.withLock { _ = $0.insert(ch) } },
            stopCodex: { ch in stopped.withLock { _ = $0.insert(ch) } },
            stopGrok: { ch in stopped.withLock { _ = $0.insert(ch) } },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false }
        )
        let n = await life.stopAll(actorId: "admin", guildId: "g")
        #expect(n == 1)
        #expect(stopped.withLock { $0 }.contains("live"))
        #expect(!stopped.withLock { $0 }.contains("arch"))
        // Hard-stop removed live; archived remains on disk.
        #expect(await store.binding(channelId: "live") == nil)
        #expect(await store.binding(channelId: "arch")?.archived == true)
    }

    /// Agent-close path: lifecycle stop is the single funnel (was unbind-only = process leak).
    @Test func agentClosePathStopsBackend() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        await reg.bind(channelId: "c", SessionConfig(backend: .grok))
        try await store.upsert(
            channelId: "c",
            PersistedSession(backend: .grok, backendSessionId: "s1", cwd: "/x", guildId: "g", updatedAt: "t")
        )
        let stopped = LockedBox(false)
        let life = SessionLifecycle(
            registry: reg,
            store: store,
            audit: tempAudit(),
            stopClaude: { _ in },
            stopCodex: { _ in },
            stopGrok: { _ in stopped.withLock { $0 = true } },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false }
        )
        _ = await life.stopChannel(channelId: "c", actorId: "owner", guildId: "g")
        #expect(stopped.withLock { $0 } == true)
        #expect(await reg.binding(channelId: "c") == nil)
        #expect(await store.binding(channelId: "c") == nil)
    }

}

@Suite("SessionRegistry.list")
struct SessionRegistryListTests {
    @Test func listReturnsAllBindings() async {
        let reg = SessionRegistry()
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude))
        await reg.bind(channelId: "c2", SessionConfig(backend: .codex))
        let all = await reg.list()
        #expect(all.count == 2)
        #expect(all["c1"]?.backend == .claude)
        #expect(all["c2"]?.backend == .codex)
    }
}

@Suite("stop/stop-all slash specs")
struct StopSlashSpecTests {
    @Test func stopAndStopAllAreLeafCommands() {
        let stop = stopCommandSpec()
        let stopAll = stopAllCommandSpec()
        #expect(stop.name == "stop")
        #expect(stop.subcommands.isEmpty)
        #expect(stopAll.name == "stop-all")
        #expect(stopAll.subcommands.isEmpty)
        let names = allSlashCommandSpecs().map(\.name)
        #expect(names == ["agent", "stop", "stop-all"])
    }
}

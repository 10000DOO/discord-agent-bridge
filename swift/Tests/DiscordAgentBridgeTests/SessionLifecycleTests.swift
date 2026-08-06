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

    // MARK: - W11-d clear / rebind / update

    @Test func clearKeepsConfigWipesBackendSessionIdAndStopsBridges() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        await reg.bind(
            channelId: "c1",
            SessionConfig(backend: .claude, model: "sonnet", effort: "high", permMode: "plan")
        )
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude, backendSessionId: "B-OLD", cwd: "/proj", guildId: "g",
                model: "sonnet", effort: "high", permMode: "plan", updatedAt: "t0"
            )
        )
        let stopped = LockedBox<[String]>([])
        let life = SessionLifecycle(
            registry: reg,
            store: store,
            audit: tempAudit(),
            stopClaude: { ch in stopped.withLock { $0.append("claude:\(ch)") } },
            stopCodex: { ch in stopped.withLock { $0.append("codex:\(ch)") } },
            stopGrok: { ch in stopped.withLock { $0.append("grok:\(ch)") } },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false },
            now: { "T-clear" }
        )
        #expect(await life.clearChannel(channelId: "c1", actorId: "u", guildId: "g") == true)
        // T-clear-1: config preserved, backendSessionId gone.
        let s = await store.binding(channelId: "c1")
        #expect(s?.backendSessionId == nil)
        #expect(s?.model == "sonnet")
        #expect(s?.effort == "high")
        #expect(s?.permMode == "plan")
        #expect(s?.cwd == "/proj")
        #expect(s?.backend == .claude)
        #expect(s?.updatedAt == "T-clear")
        // Registry still bound with same config (not unbound).
        #expect(await reg.binding(channelId: "c1") == SessionConfig(
            backend: .claude, model: "sonnet", effort: "high", permMode: "plan"
        ))
        #expect(stopped.withLock { $0 } == ["claude:c1", "codex:c1", "grok:c1"])
    }

    // design_orchestration_project_scoped_command.md §4.5 / design_orchestration_module_agents.md
    // R12/D18: enableOrchestrationMode mirrors clearChannel (store upsert → stop all bridges →
    // registry rebind), plus flips orchestrationSession so the next session start removes the
    // subagent-launch tool from the model's context.
    @Test func enableOrchestrationModeSetsProjectFlagWipesBackendSessionIdAndStopsBridges() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        await reg.bind(
            channelId: "c1",
            SessionConfig(backend: .claude, model: "sonnet", effort: "high", permMode: "plan")
        )
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude, backendSessionId: "B-OLD", cwd: "/proj", guildId: "g",
                model: "sonnet", effort: "high", permMode: "plan", updatedAt: "t0"
            )
        )
        let stopped = LockedBox<[String]>([])
        let life = SessionLifecycle(
            registry: reg,
            store: store,
            audit: tempAudit(),
            stopClaude: { ch in stopped.withLock { $0.append("claude:\(ch)") } },
            stopCodex: { ch in stopped.withLock { $0.append("codex:\(ch)") } },
            stopGrok: { ch in stopped.withLock { $0.append("grok:\(ch)") } },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false },
            now: { "T-orch" }
        )
        #expect(await life.enableOrchestrationMode(channelId: "c1", actorId: "u", guildId: "g") == true)
        let s = await store.binding(channelId: "c1")
        #expect(s?.orchestrationSession == true)
        #expect(s?.orchestrationRole == "orchestrator")
        #expect(s?.backendSessionId == nil)
        #expect(s?.model == "sonnet") // config otherwise preserved, same as clearChannel
        #expect(s?.cwd == "/proj")
        #expect(s?.updatedAt == "T-orch")
        #expect(stopped.withLock { $0 } == ["claude:c1", "codex:c1", "grok:c1"])

        // Calling again (re-run of /orchestration) is idempotent — still true, no separate branch.
        #expect(await life.enableOrchestrationMode(channelId: "c1", actorId: "u", guildId: "g") == true)
        #expect(await store.binding(channelId: "c1")?.orchestrationSession == true)
    }

    @Test func orchestrationProjectFlagSurvivesSessionPersistenceAcrossClear() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude, cwd: "/proj", guildId: "g", updatedAt: "t0"
            )
        )
        let life = SessionLifecycle(
            registry: reg,
            store: store,
            audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        #expect(await life.enableOrchestrationMode(channelId: "c1", actorId: "u", guildId: "g"))
        let firstGeneration = try #require(await store.binding(channelId: "c1")?.lifecycleGeneration)
        await persistSession(
            store: store, backend: .claude, channelId: "c1", guildId: "g", ownerId: "u",
            cwd: "/proj", model: nil, effort: nil, permMode: nil, backendSessionId: "B-FIRST",
            lifecycleGeneration: firstGeneration
        )
        #expect(await store.binding(channelId: "c1")?.orchestrationSession == true)

        #expect(await life.clearChannel(channelId: "c1", actorId: "u", guildId: "g"))
        let secondGeneration = try #require(await store.binding(channelId: "c1")?.lifecycleGeneration)
        await persistSession(
            store: store, backend: .claude, channelId: "c1", guildId: "g", ownerId: "u",
            cwd: "/proj", model: nil, effort: nil, permMode: nil, backendSessionId: "B-SECOND",
            lifecycleGeneration: secondGeneration
        )

        let persisted = await store.binding(channelId: "c1")
        #expect(persisted?.backendSessionId == "B-SECOND")
        #expect(persisted?.orchestrationSession == true)
    }

    @Test func enableOrchestrationModeNoBindingReturnsFalse() async {
        let life = SessionLifecycle(
            registry: SessionRegistry(),
            store: freshTempStore(),
            audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )
        #expect(await life.enableOrchestrationMode(channelId: "none", actorId: "u", guildId: "g") == false)
    }

    // MARK: - WO-2 startModuleAgentChannel

    @Test func startModuleAgentChannelBindsStoreAndRegistryAsAgent() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            now: { "T-agent" }
        )
        let config = SessionConfig(backend: .claude, model: "sonnet", effort: "medium", permMode: "acceptEdits")
        let ok = await life.startModuleAgentChannel(
            channelId: "agent-core",
            guildId: "g",
            ownerId: "owner-1",
            cwd: "/repo/core",
            moduleName: "core",
            orchestratorChannelId: "orc-1",
            config: config,
            actorId: "u"
        )
        #expect(ok == true)
        let s = await store.binding(channelId: "agent-core")
        #expect(s?.orchestrationRole == "agent")
        #expect(s?.orchestratorChannelId == "orc-1")
        #expect(s?.moduleName == "core")
        #expect(s?.backend == .claude)
        #expect(s?.model == "sonnet")
        #expect(s?.effort == "medium")
        #expect(s?.permMode == "acceptEdits")
        #expect(s?.cwd == "/repo/core")
        #expect(s?.orchestrationSession == true)
        #expect(await reg.binding(channelId: "agent-core")?.backend == .claude)
        #expect(await reg.binding(channelId: "agent-core")?.model == "sonnet")
    }

    // RV (high): a re-call onto an already-bound module channel must stop any bridge already
    // live on it before rebinding — same ordering as clearChannel/enableOrchestrationMode — so a
    // future caller (WO-3/WO-4) can never orphan a process under a new lifecycleGeneration.
    @Test func startModuleAgentChannelIsIdempotentOnRecall() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let stopped = LockedBox<[String]>([])
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { ch in stopped.withLock { $0.append("claude:\(ch)") } },
            stopCodex: { ch in stopped.withLock { $0.append("codex:\(ch)") } },
            stopGrok: { ch in stopped.withLock { $0.append("grok:\(ch)") } },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            now: { "T-agent" }
        )
        let config = SessionConfig(backend: .claude, model: "sonnet")
        #expect(await life.startModuleAgentChannel(
            channelId: "agent-core", guildId: "g", ownerId: "owner-1", cwd: "/repo/core",
            moduleName: "core", orchestratorChannelId: "orc-1", config: config, actorId: "u"
        ) == true)
        // First call already stops all three (nothing was live yet, but the ordering is unconditional).
        #expect(stopped.withLock { $0 } == ["claude:agent-core", "codex:agent-core", "grok:agent-core"])

        #expect(await life.startModuleAgentChannel(
            channelId: "agent-core", guildId: "g", ownerId: "owner-1", cwd: "/repo/core",
            moduleName: "core", orchestratorChannelId: "orc-1", config: config, actorId: "u"
        ) == true)
        // Second call (the orphan-risk case) stops all three again before rebinding.
        #expect(stopped.withLock { $0 } == [
            "claude:agent-core", "codex:agent-core", "grok:agent-core",
            "claude:agent-core", "codex:agent-core", "grok:agent-core",
        ])
        #expect(await store.all().count == 1)
        #expect(await store.binding(channelId: "agent-core")?.orchestrationRole == "agent")
    }

    @Test func clearNoBindingReturnsFalse() async {
        let life = SessionLifecycle(
            registry: SessionRegistry(),
            store: freshTempStore(),
            audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )
        #expect(await life.clearChannel(channelId: "none", actorId: "u", guildId: "g") == false)
    }

    @Test func lifecycleGenerationRejectsLateSameBackendPersistenceAfterClearRebindAndStop() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let original = PersistedSession(
            backend: .claude, backendSessionId: "old-id", cwd: "/old", guildId: "g",
            lifecycleGeneration: "old-generation", updatedAt: "T0"
        )
        try await store.upsert(channelId: "c1", original)
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude))
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            now: { "T-next" }
        )

        #expect(await life.clearChannel(channelId: "c1", actorId: "u", guildId: "g"))
        let afterClear = await store.binding(channelId: "c1")
        await persistSession(
            store: store, backend: .claude, channelId: "c1", guildId: "g", ownerId: "u",
            cwd: "/stale", model: "old", effort: nil, permMode: nil, backendSessionId: "late-id",
            lifecycleGeneration: "old-generation"
        )
        #expect(await store.binding(channelId: "c1") == afterClear)

        #expect(await life.rebindBackend(channelId: "c1", backend: .claude, actorId: "u", guildId: "g"))
        let afterRebind = await store.binding(channelId: "c1")
        await persistSession(
            store: store, backend: .claude, channelId: "c1", guildId: "g", ownerId: "u",
            cwd: "/stale", model: "old", effort: nil, permMode: nil, backendSessionId: "late-id",
            lifecycleGeneration: "old-generation"
        )
        #expect(await store.binding(channelId: "c1") == afterRebind)

        #expect(await life.stopChannel(channelId: "c1", actorId: "u", guildId: "g"))
        await persistSession(
            store: store, backend: .claude, channelId: "c1", guildId: "g", ownerId: "u",
            cwd: "/stale", model: "old", effort: nil, permMode: nil, backendSessionId: "late-id",
            lifecycleGeneration: "old-generation"
        )
        #expect(await store.binding(channelId: "c1") == nil)
    }

    @Test func clearDoesNotStopOrRebindWhenDurableSaveFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dab-store-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notDirectory = root.appendingPathComponent("not-a-directory")
        try Data().write(to: notDirectory)

        let reg = SessionRegistry()
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude, model: "old"))
        let stopped = LockedBox(0)
        let life = SessionLifecycle(
            registry: reg,
            store: SessionStore(fileURL: notDirectory.appendingPathComponent("state.json")),
            audit: tempAudit(),
            stopClaude: { _ in stopped.withLock { $0 += 1 } },
            stopCodex: { _ in stopped.withLock { $0 += 1 } },
            stopGrok: { _ in stopped.withLock { $0 += 1 } },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false }
        )

        #expect(await life.clearChannel(channelId: "c1", actorId: "u", guildId: "g") == false)
        #expect(stopped.withLock { $0 } == 0)
        #expect(await reg.binding(channelId: "c1") == SessionConfig(backend: .claude, model: "old"))
    }

    @Test func updateBindingPatchesModelWithoutStopping() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .codex, backendSessionId: "t1", cwd: "/x", guildId: "g",
                model: "old", effort: "low", permMode: "default", updatedAt: "t0"
            )
        )
        await reg.bind(channelId: "c1", SessionConfig(backend: .codex, model: "old", effort: "low"))
        let stopped = LockedBox(0)
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in stopped.withLock { $0 += 1 } },
            stopCodex: { _ in stopped.withLock { $0 += 1 } },
            stopGrok: { _ in stopped.withLock { $0 += 1 } },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            now: { "T-model" }
        )
        #expect(await life.updateBinding(
            channelId: "c1", patch: BindingPatch(model: "new-model"),
            actorId: "u", guildId: "g"
        ) == .ok)
        #expect(stopped.withLock { $0 } == 0)
        #expect(await store.binding(channelId: "c1")?.model == "new-model")
        #expect(await store.binding(channelId: "c1")?.backendSessionId == "t1")
        #expect(await store.binding(channelId: "c1")?.effort == "low")
        #expect(await reg.binding(channelId: "c1")?.model == "new-model")
    }

    // W11-g residual: Claude /model and /effort push live setModel/setEffort when bound.
    @Test func updateBindingClaudePushesLiveSetModelAndEffort() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude, backendSessionId: "B", cwd: "/x", guildId: "g",
                model: "old", effort: "low", permMode: "default", updatedAt: "t0"
            )
        )
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude, model: "old", effort: "low"))
        let live = LockedBox<[String]>([])
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            setModelClaude: { ch, m in live.withLock { $0.append("model:\(ch):\(m)") }; return true },
            setEffortClaude: { ch, e in live.withLock { $0.append("effort:\(ch):\(e)") }; return true },
            now: { "T-live" }
        )
        #expect(await life.updateBinding(
            channelId: "c1", patch: BindingPatch(model: "sonnet"),
            actorId: "u", guildId: "g"
        ) == .ok)
        #expect(await life.updateBinding(
            channelId: "c1", patch: BindingPatch(effort: "high"),
            actorId: "u", guildId: "g"
        ) == .ok)
        #expect(live.withLock { $0 } == ["model:c1:sonnet", "effort:c1:high"])
        #expect(await store.binding(channelId: "c1")?.model == "sonnet")
        #expect(await store.binding(channelId: "c1")?.effort == "high")
        #expect(await store.binding(channelId: "c1")?.backendSessionId == "B")
    }

    @Test func updateBindingCodexDoesNotPushClaudeLiveSetModel() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .codex, backendSessionId: "t1", cwd: "/x", guildId: "g",
                model: "old", updatedAt: "t0"
            )
        )
        await reg.bind(channelId: "c1", SessionConfig(backend: .codex, model: "old"))
        let live = LockedBox(0)
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            setModelClaude: { _, _ in live.withLock { $0 += 1 }; return true },
            setEffortClaude: { _, _ in live.withLock { $0 += 1 }; return true },
            now: { "T-codex" }
        )
        #expect(await life.updateBinding(
            channelId: "c1", patch: BindingPatch(model: "gpt-5"),
            actorId: "u", guildId: "g"
        ) == .ok)
        #expect(live.withLock { $0 } == 0)
        #expect(await store.binding(channelId: "c1")?.model == "gpt-5")
    }

    @Test func updateBindingKeepsGenerationAndMatchingCallbackOnlyUpdatesBackendSessionId() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let original = PersistedSession(
            backend: .grok, backendSessionId: "old-id", cwd: "/workspace", guildId: "current-guild",
            ownerId: "current-owner", model: "old-model", effort: "low", permMode: "read-only",
            lifecycleGeneration: "live-generation", updatedAt: "T0"
        )
        try await store.upsert(channelId: "c1", original)
        await reg.bind(channelId: "c1", SessionConfig(backend: .grok, model: "old-model", effort: "low", permMode: "read-only"))
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            now: { "T-update" }
        )

        #expect(await life.updateBinding(
            channelId: "c1",
            patch: BindingPatch(model: "current-model", effort: "high", permMode: "workspace-write"),
            actorId: "u", guildId: "current-guild"
        ) == .ok)
        #expect(await store.binding(channelId: "c1")?.lifecycleGeneration == "live-generation")

        await persistSession(
            store: store, backend: .grok, channelId: "c1", guildId: "stale-guild", ownerId: "stale-owner",
            cwd: "/stale", model: "stale-model", effort: "low", permMode: "read-only",
            backendSessionId: "new-backend-id", lifecycleGeneration: "live-generation"
        )

        let persisted = await store.binding(channelId: "c1")
        #expect(persisted?.backendSessionId == "new-backend-id")
        #expect(persisted?.guildId == "current-guild")
        #expect(persisted?.ownerId == "current-owner")
        #expect(persisted?.model == "current-model")
        #expect(persisted?.effort == "high")
        #expect(persisted?.permMode == "workspace-write")
    }

    @Test func replaceBindingPersistsThenStopsOldBridgesBeforeRegistryPublish() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let original = PersistedSession(
            backend: .claude, backendSessionId: "old-id", cwd: "/old", guildId: "g", updatedAt: "T0"
        )
        try await store.upsert(channelId: "c1", original)
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude, model: "old"))
        let observedDuringStop = LockedBox<(PersistedSession?, SessionConfig?)>((nil, nil))
        let replacement = PersistedSession(
            backend: .codex, backendSessionId: nil, cwd: "/new", guildId: "g", model: "new", effort: "high",
            permMode: "workspace-write", lifecycleGeneration: "replacement-generation", updatedAt: "T1"
        )
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in
                let stored = await store.binding(channelId: "c1")
                let bound = await reg.binding(channelId: "c1")
                observedDuringStop.withLock { $0 = (stored, bound) }
            },
            stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        #expect(await life.replaceBinding(channelId: "c1", with: replacement))
        let duringStop = observedDuringStop.withLock { $0 }
        #expect(duringStop.0?.backend == replacement.backend)
        #expect(duringStop.0?.backendSessionId == nil)
        #expect(duringStop.0?.lifecycleGeneration != original.lifecycleGeneration)
        #expect(duringStop.1 == SessionConfig(backend: .claude, model: "old"))
        #expect(await reg.binding(channelId: "c1") == SessionConfig(
            backend: .codex, model: "new", effort: "high", permMode: "workspace-write"
        ))
    }

    // `/agent start` can land back on the channel it was run in (`resolveSessionChannelId`'s
    // fallback). The new session must not demote a lead channel — a wiped role makes `order`
    // answer `.wrongRole`, so the orchestrator can no longer open module sessions, and
    // `/agent close` stops tearing the set down.
    @Test func replaceBindingKeepsChannelOrchestrationRole() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "lead", PersistedSession(
            backend: .claude, cwd: "/repo", guildId: "g", updatedAt: "T0",
            orchestrationSession: true, orchestrationRole: "orchestrator"
        ))
        try await store.upsert(channelId: "mod", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "T0",
            orchestrationSession: true, orchestrationRole: "agent",
            orchestratorChannelId: "lead", moduleName: "core"
        ))
        let life = SessionLifecycle(
            registry: SessionRegistry(), store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )
        // A wizard record never carries these fields — that is exactly the wipe being guarded.
        let fromWizard = PersistedSession(
            backend: .claude, cwd: "/repo", guildId: "g", model: "opus", updatedAt: "T1"
        )

        #expect(await life.replaceBinding(channelId: "lead", with: fromWizard))
        #expect(await life.replaceBinding(channelId: "mod", with: fromWizard))

        let lead = await store.binding(channelId: "lead")
        #expect(lead?.orchestrationRole == "orchestrator")
        #expect(lead?.orchestrationSession == true)
        #expect(lead?.model == "opus") // the wizard's own choices still take effect
        let mod = await store.binding(channelId: "mod")
        #expect(mod?.orchestrationRole == "agent")
        #expect(mod?.orchestratorChannelId == "lead")
        #expect(mod?.moduleName == "core")

        // An ordinary channel with no prior row stays roleless.
        #expect(await life.replaceBinding(channelId: "plain", with: fromWizard))
        #expect(await store.binding(channelId: "plain")?.orchestrationRole == nil)
    }

    // C4-a: a failed live setModel must not be persisted — the binding stays at its old
    // model/effort and the caller learns the switch failed instead of a silent "success".
    @Test func updateBindingClaudeDoesNotPersistWhenLiveApplyFails() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude, backendSessionId: "B", cwd: "/x", guildId: "g",
                model: "old", effort: "low", updatedAt: "t0"
            )
        )
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude, model: "old", effort: "low"))
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            setModelClaude: { _, _ in false },
            setEffortClaude: { _, _ in true },
            now: { "T-fail" }
        )
        #expect(await life.updateBinding(
            channelId: "c1", patch: BindingPatch(model: "new-model"),
            actorId: "u", guildId: "g"
        ) == .applyFailed)
        #expect(await store.binding(channelId: "c1")?.model == "old")
        #expect(await reg.binding(channelId: "c1")?.model == "old")
    }

    // M11: an unknown codex effort value must be rejected before it is ever persisted.
    @Test func updateBindingCodexRejectsUnknownEffort() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .codex, backendSessionId: "t1", cwd: "/x", guildId: "g",
                effort: "low", updatedAt: "t0"
            )
        )
        await reg.bind(channelId: "c1", SessionConfig(backend: .codex, effort: "low"))
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            isKnownCodexEffort: { _ in false },
            now: { "T-effort" }
        )
        #expect(await life.updateBinding(
            channelId: "c1", patch: BindingPatch(effort: "not-a-real-effort"),
            actorId: "u", guildId: "g"
        ) == .invalidEffort)
        #expect(await store.binding(channelId: "c1")?.effort == "low")
        #expect(await reg.binding(channelId: "c1")?.effort == "low")
    }

    // G-P1-04: /mode perm profile path persists permissionProfile + resolved permMode.
    @Test func updateBindingModePermProfilePersistsProfileAndPermMode() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude, backendSessionId: "B", cwd: "/x", guildId: "g",
                model: "opus", effort: "high", permMode: "default",
                permissionProfile: nil, updatedAt: "t0"
            )
        )
        await reg.bind(
            channelId: "c1",
            SessionConfig(backend: .claude, model: "opus", effort: "high", permMode: "default")
        )
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            now: { "T-perm-prof" }
        )
        let profiles: [String: Profile] = [
            "readonly": Profile(
                permissionMode: "plan",
                allowedTools: ["Read"],
                policyTier: "read-only"
            ),
        ]
        let resolved = resolveModePerm(value: "readonly", profiles: profiles)
        #expect(await life.updateBinding(
            channelId: "c1", patch: resolved.bindingPatch,
            actorId: "u", guildId: "g"
        ) == .ok)
        let row = await store.binding(channelId: "c1")
        #expect(row?.permMode == "plan")
        #expect(row?.permissionProfile == "readonly")
        #expect(row?.model == "opus")
        #expect(row?.effort == "high")
        #expect(row?.backendSessionId == "B")
        #expect(await reg.binding(channelId: "c1")?.permMode == "plan")

        // Raw mode keeps the stored profile (TS: profile not in override).
        let raw = resolveModePerm(value: "acceptEdits", profiles: profiles)
        #expect(await life.updateBinding(
            channelId: "c1", patch: raw.bindingPatch,
            actorId: "u", guildId: "g"
        ) == .ok)
        let afterRaw = await store.binding(channelId: "c1")
        #expect(afterRaw?.permMode == "acceptEdits")
        #expect(afterRaw?.permissionProfile == "readonly")
    }

    @Test func rebindBackendSameKeepsModelDifferentDrops() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude, backendSessionId: "B", cwd: "/x", guildId: "g",
                model: "sonnet", effort: "high", permMode: "plan", updatedAt: "t0"
            )
        )
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude, model: "sonnet", effort: "high", permMode: "plan"))
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            now: { "T-mode" }
        )
        // Same backend: keep model/effort, clear session id.
        #expect(await life.rebindBackend(channelId: "c1", backend: .claude, actorId: "u", guildId: "g") == true)
        #expect(await store.binding(channelId: "c1")?.backendSessionId == nil)
        #expect(await store.binding(channelId: "c1")?.model == "sonnet")
        #expect(await store.binding(channelId: "c1")?.effort == "high")

        // Restore id for second switch.
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude, backendSessionId: "B2", cwd: "/x", guildId: "g",
                model: "sonnet", effort: "high", permMode: "plan", updatedAt: "t1"
            )
        )
        #expect(await life.rebindBackend(channelId: "c1", backend: .codex, actorId: "u", guildId: "g") == true)
        let s = await store.binding(channelId: "c1")
        #expect(s?.backend == .codex)
        #expect(s?.backendSessionId == nil)
        #expect(s?.model == nil)
        #expect(s?.effort == nil)
        #expect(s?.permMode == "plan")
        #expect(await reg.binding(channelId: "c1")?.backend == .codex)
    }

    @Test func reconfigureBindingStopsAndAppliesWizardChoices() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude, backendSessionId: "live", cwd: "/proj", guildId: "g",
                ownerId: "owner-1", model: "sonnet", effort: "high", permMode: "plan", updatedAt: "t0"
            )
        )
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude, model: "sonnet", effort: "high", permMode: "plan"))
        let stopped = LockedBox<[String]>([])
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { ch in stopped.withLock { $0.append("claude:\(ch)") } },
            stopCodex: { ch in stopped.withLock { $0.append("codex:\(ch)") } },
            stopGrok: { ch in stopped.withLock { $0.append("grok:\(ch)") } },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false },
            now: { "T-recfg" }
        )
        #expect(await life.reconfigureBinding(
            channelId: "c1",
            backend: .codex,
            model: "gpt-5.4",
            effort: "high",
            permMode: "workspace-write",
            actorId: "u",
            guildId: "g"
        ) == true)
        // All bridges stopped (fresh context).
        #expect(stopped.withLock { $0 }.contains("claude:c1"))
        #expect(stopped.withLock { $0 }.contains("codex:c1"))
        #expect(stopped.withLock { $0 }.contains("grok:c1"))
        let s = await store.binding(channelId: "c1")
        #expect(s?.backend == .codex)
        #expect(s?.backendSessionId == nil)
        #expect(s?.model == "gpt-5.4")
        #expect(s?.effort == "high")
        #expect(s?.permMode == "workspace-write")
        #expect(s?.cwd == "/proj")
        #expect(s?.ownerId == "owner-1")
        #expect(s?.updatedAt == "T-recfg")
        let cfg = await reg.binding(channelId: "c1")
        #expect(cfg?.backend == .codex)
        #expect(cfg?.model == "gpt-5.4")
        #expect(cfg?.effort == "high")
        #expect(cfg?.permMode == "workspace-write")
    }

    @Test func reconfigureBindingNoSessionReturnsFalse() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )
        #expect(await life.reconfigureBinding(
            channelId: "missing",
            backend: .codex,
            model: "gpt-5.4",
            effort: "high",
            permMode: "read-only",
            actorId: "u",
            guildId: "g"
        ) == false)
    }

    @Test func resumeBindingFromStore() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .grok, backendSessionId: "s1", cwd: "/x", guildId: "g",
                model: "g1", updatedAt: "t"
            )
        )
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )
        #expect(await life.resumeBinding(channelId: "missing") == nil)
        let row = await life.resumeBinding(channelId: "c1")
        #expect(row?.backend == .grok)
        #expect(row?.model == "g1")
        #expect(row?.cwd == "/x")
        #expect(row?.backendSessionId == "s1")
        #expect(await reg.binding(channelId: "c1")?.backend == .grok)
        #expect(await reg.binding(channelId: "c1")?.model == "g1")
    }

    @Test func resumeSkipsArchived() async throws {
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(backend: .claude, cwd: "/x", guildId: "g", updatedAt: "t", archived: true)
        )
        let life = SessionLifecycle(
            registry: SessionRegistry(), store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )
        #expect(await life.resumeBinding(channelId: "c1") == nil)
    }

    // MARK: - C10 resumeAll (boot recovery)

    @Test func resumeAllCleansUpGoneChannelWithoutCallingResumeSession() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude))
        try await store.upsert(
            channelId: "c1",
            PersistedSession(backend: .claude, backendSessionId: "B", cwd: "/x", guildId: "g", updatedAt: "t")
        )
        let stopped = LockedBox<[String]>([])
        let resumedCalls = LockedBox<[String]>([])
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
        let summary = await life.resumeAll(
            channelGone: { _ in true },
            resumeSession: { ch in resumedCalls.withLock { $0.append(ch) }; return true }
        )
        #expect(summary.total == 1)
        #expect(summary.resumed == 0)
        #expect(summary.cleaned == 1)
        // Gone → hard-cleaned via the exact same path as stopChannel/onChannelDelete, never resumed.
        #expect(resumedCalls.withLock { $0 }.isEmpty)
        #expect(stopped.withLock { $0 } == ["claude:c1", "codex:c1", "grok:c1"])
        #expect(await reg.binding(channelId: "c1") == nil)
        #expect(await store.binding(channelId: "c1") == nil)
    }

    @Test func resumeAllResumesLiveChannelWithoutStopping() async throws {
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(backend: .codex, backendSessionId: "t1", cwd: "/x", guildId: "g", updatedAt: "t")
        )
        let stopped = LockedBox(0)
        let resumedCalls = LockedBox<[String]>([])
        let life = SessionLifecycle(
            registry: SessionRegistry(),
            store: store,
            audit: tempAudit(),
            stopClaude: { _ in stopped.withLock { $0 += 1 } },
            stopCodex: { _ in stopped.withLock { $0 += 1 } },
            stopGrok: { _ in stopped.withLock { $0 += 1 } },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false }
        )
        let summary = await life.resumeAll(
            channelGone: { _ in false },
            resumeSession: { ch in resumedCalls.withLock { $0.append(ch) }; return true }
        )
        #expect(summary.total == 1)
        #expect(summary.resumed == 1)
        #expect(summary.cleaned == 0)
        // Not gone → resumed, never stopped, binding untouched.
        #expect(resumedCalls.withLock { $0 } == ["c1"])
        #expect(stopped.withLock { $0 } == 0)
        #expect(await store.binding(channelId: "c1")?.backendSessionId == "t1")
    }

    @Test func resumeAllHandlesEachChannelIndependently() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        for ch in ["gone1", "live1", "live2"] {
            await reg.bind(channelId: ch, SessionConfig(backend: .grok))
            try await store.upsert(
                channelId: ch,
                PersistedSession(backend: .grok, backendSessionId: "s-\(ch)", cwd: "/x", guildId: "g", updatedAt: "t")
            )
        }
        let stopped = LockedBox<Set<String>>([])
        let resumedCalls = LockedBox<Set<String>>([])
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
        let summary = await life.resumeAll(
            channelGone: { ch in ch == "gone1" },
            resumeSession: { ch in
                resumedCalls.withLock { _ = $0.insert(ch) }
                return ch == "live1" // live2 "fails" to resume — must not affect gone1 / live1's outcomes.
            }
        )
        #expect(summary.total == 3)
        #expect(summary.cleaned == 1)
        #expect(summary.resumed == 1)
        // gone1: stopped, never asked to resume.
        #expect(stopped.withLock { $0 }.contains("gone1"))
        #expect(!resumedCalls.withLock { $0 }.contains("gone1"))
        #expect(await store.binding(channelId: "gone1") == nil)
        // live1: resumed successfully, never stopped.
        #expect(resumedCalls.withLock { $0 }.contains("live1"))
        #expect(!stopped.withLock { $0 }.contains("live1"))
        #expect(await store.binding(channelId: "live1") != nil)
        // live2: resume attempted and failed — still not stopped (a failed resume is not a deletion),
        // and does not affect live1's success or gone1's cleanup (Promise.allSettled tolerance).
        #expect(resumedCalls.withLock { $0 }.contains("live2"))
        #expect(!stopped.withLock { $0 }.contains("live2"))
        #expect(await store.binding(channelId: "live2") != nil)
    }
}

// MARK: - WO-7 closeOrchestrationSet (design_orchestration_module_agents.md, R8)

/// Minimal provisioner fake for `closeOrchestrationSet`: tracks parent-per-channel-id so
/// `childChannelIds` can answer the category-empty check for real, mirroring
/// `OrchestrationChannelsTests.swift`'s `FakeProvisioner` (kept separate — that one is file-private).
private final class OrchestrationCloseFakeProvisioner: GuildChannelProvisioner, @unchecked Sendable {
    private enum FakeQueryError: Error { case simulated }

    let guildId: String
    /// channelId → parentId
    private(set) var channels: [String: String?] = [:]
    private(set) var deleted: [String] = []
    /// When true, `childChannelIds` throws instead of answering (RV: a failed live query must
    /// never be read as "empty").
    var failChildQuery = false

    init(guildId: String = "g") { self.guildId = guildId }

    func seed(id: String, parentId: String?) { channels[id] = parentId }

    func canManageChannels() async -> Bool { true }
    func channelExists(_ id: String) async -> Bool { channels[id] != nil }
    func ensureCategory(name: String, existingId: String?) async throws -> ProvisionedChannel {
        ProvisionedChannel(id: existingId ?? "cat", name: name)
    }
    func ensureTextChannel(name: String, parentId: String, existingId: String?) async throws -> ProvisionedChannel {
        ProvisionedChannel(id: existingId ?? "text", name: name)
    }
    func createTextChannel(name: String, parentId: String?) async throws -> ProvisionedChannel {
        ProvisionedChannel(id: "text", name: name)
    }
    func renameChannel(id: String, name: String) async throws {}
    func setParent(id: String, parentId: String) async throws {}
    func deleteChannel(id: String) async throws {
        channels.removeValue(forKey: id)
        deleted.append(id)
    }
    func childChannelIds(categoryId: String) async throws -> [String] {
        if failChildQuery { throw FakeQueryError.simulated }
        return channels.filter { $0.value == categoryId }.map(\.key)
    }
}

private func orchestrationConfigStore(
    guildId: String, orchestratorChannelId: String, categoryId: String
) async throws -> ConfigStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-orch-close-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = ConfigStore(baseDir: dir)
    try await store.saveServerConfig(ServerConfig(
        guildId: guildId,
        orchestration: [orchestratorChannelId: OrchestrationSet(categoryId: categoryId)]
    ))
    return store
}

@Suite("SessionLifecycle closeOrchestrationSet")
struct SessionLifecycleCloseOrchestrationSetTests {
    private func tempAudit() -> AuditLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-audit-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit.jsonl", isDirectory: false)
        return AuditLog(fileURL: url, now: { "T" })
    }

    // Completion criterion ③: total close stops+deletes 2 modules and removes the category.
    @Test func closesModulesDeletesEmptyCategoryAndRemovesConfigEntry() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let configStore = try await orchestrationConfigStore(
            guildId: "g", orchestratorChannelId: "orc-1", categoryId: "cat-1"
        )
        let prov = OrchestrationCloseFakeProvisioner(guildId: "g")
        prov.seed(id: "orc-1", parentId: "cat-1") // lead channel — still physically present here
        prov.seed(id: "agent-core", parentId: "cat-1")
        prov.seed(id: "agent-ui", parentId: "cat-1")

        try await store.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))
        try await store.upsert(channelId: "agent-ui", PersistedSession(
            backend: .claude, cwd: "/repo/ui", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "ui"
        ))
        await reg.bind(channelId: "agent-core", SessionConfig(backend: .claude))
        await reg.bind(channelId: "agent-ui", SessionConfig(backend: .claude))

        let stopped = LockedBox<Set<String>>([])
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { ch in stopped.withLock { _ = $0.insert(ch) } },
            stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        let count = await life.closeOrchestrationSet(
            orchestratorChannelId: "orc-1", guildId: "g", actorId: "u",
            provisioner: prov, configStore: configStore
        )

        #expect(count == 2)
        #expect(stopped.withLock { $0 } == ["agent-core", "agent-ui"])
        #expect(await store.binding(channelId: "agent-core") == nil)
        #expect(await store.binding(channelId: "agent-ui") == nil)
        #expect(await reg.binding(channelId: "agent-core") == nil)
        #expect(Set(prov.deleted) == ["agent-core", "agent-ui", "cat-1"])
        #expect(await configStore.loadServerConfig(guildId: "g")?.orchestration?["orc-1"] == nil)
    }

    // The reason Option 1 (real Discord query) was picked over trusting the store alone: a
    // channel dropped into the category outside of our own bookkeeping must block category
    // deletion instead of silently vanishing along with it.
    @Test func doesNotDeleteCategoryWhenStrayChannelRemains() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let configStore = try await orchestrationConfigStore(
            guildId: "g", orchestratorChannelId: "orc-1", categoryId: "cat-1"
        )
        let prov = OrchestrationCloseFakeProvisioner(guildId: "g")
        prov.seed(id: "orc-1", parentId: "cat-1")
        prov.seed(id: "agent-core", parentId: "cat-1")
        prov.seed(id: "stray-manual-channel", parentId: "cat-1") // never tracked in the store

        try await store.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))

        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        _ = await life.closeOrchestrationSet(
            orchestratorChannelId: "orc-1", guildId: "g", actorId: "u",
            provisioner: prov, configStore: configStore
        )

        #expect(prov.deleted == ["agent-core"]) // module gone, category left alone
        #expect(await configStore.loadServerConfig(guildId: "g")?.orchestration?["orc-1"]?.categoryId == "cat-1")
        #expect(prov.channels["stray-manual-channel"] != nil)
    }

    // RV: a failed live query must not be read as "empty" — that would delete a category we never
    // actually confirmed was empty, defeating the whole reason a live check was chosen over
    // trusting the store alone.
    @Test func doesNotDeleteCategoryWhenChildQueryFails() async throws {
        let store = freshTempStore()
        let configStore = try await orchestrationConfigStore(
            guildId: "g", orchestratorChannelId: "orc-1", categoryId: "cat-1"
        )
        let prov = OrchestrationCloseFakeProvisioner(guildId: "g")
        prov.seed(id: "orc-1", parentId: "cat-1")
        prov.seed(id: "agent-core", parentId: "cat-1")
        prov.failChildQuery = true

        try await store.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))

        let life = SessionLifecycle(
            registry: SessionRegistry(), store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        let count = await life.closeOrchestrationSet(
            orchestratorChannelId: "orc-1", guildId: "g", actorId: "u",
            provisioner: prov, configStore: configStore
        )

        #expect(count == 1)
        #expect(prov.deleted == ["agent-core"]) // module still torn down, category untouched
        #expect(!prov.deleted.contains("cat-1"))
        #expect(await configStore.loadServerConfig(guildId: "g")?.orchestration?["orc-1"]?.categoryId == "cat-1")
    }

    // The emptiness check excludes `orchestratorChannelId` itself so this is safe to call whether
    // the lead channel's own physical delete already ran or not (`case "close":`'s ordering).
    @Test func categoryDeletionIgnoresLeadChannelRegardlessOfDeleteOrder() async throws {
        // Case A: lead channel already deleted by the time closeOrchestrationSet runs.
        let storeA = freshTempStore()
        let configStoreA = try await orchestrationConfigStore(
            guildId: "g", orchestratorChannelId: "orc-1", categoryId: "cat-1"
        )
        let provA = OrchestrationCloseFakeProvisioner(guildId: "g")
        provA.seed(id: "agent-core", parentId: "cat-1") // "orc-1" NOT seeded — already gone
        try await storeA.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))
        let lifeA = SessionLifecycle(
            registry: SessionRegistry(), store: storeA, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )
        _ = await lifeA.closeOrchestrationSet(
            orchestratorChannelId: "orc-1", guildId: "g", actorId: "u",
            provisioner: provA, configStore: configStoreA
        )
        #expect(provA.deleted.contains("cat-1"))

        // Case B: lead channel still physically present (not deleted yet) — same result.
        let storeB = freshTempStore()
        let configStoreB = try await orchestrationConfigStore(
            guildId: "g", orchestratorChannelId: "orc-1", categoryId: "cat-1"
        )
        let provB = OrchestrationCloseFakeProvisioner(guildId: "g")
        provB.seed(id: "orc-1", parentId: "cat-1")
        provB.seed(id: "agent-core", parentId: "cat-1")
        try await storeB.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))
        let lifeB = SessionLifecycle(
            registry: SessionRegistry(), store: storeB, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )
        _ = await lifeB.closeOrchestrationSet(
            orchestratorChannelId: "orc-1", guildId: "g", actorId: "u",
            provisioner: provB, configStore: configStoreB
        )
        #expect(provB.deleted.contains("cat-1"))
    }

    // Only the sessions bound to THIS orchestratorChannelId are torn down — a module belonging to
    // a different set (and its category) must survive.
    @Test func onlyTearsDownModulesForGivenOrchestrator() async throws {
        let store = freshTempStore()
        let configStore = try await orchestrationConfigStore(
            guildId: "g", orchestratorChannelId: "orc-1", categoryId: "cat-1"
        )
        let prov = OrchestrationCloseFakeProvisioner(guildId: "g")
        prov.seed(id: "orc-1", parentId: "cat-1")
        prov.seed(id: "agent-core", parentId: "cat-1")
        prov.seed(id: "other-agent", parentId: "cat-2")

        try await store.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))
        try await store.upsert(channelId: "other-agent", PersistedSession(
            backend: .claude, cwd: "/repo/other", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-2", moduleName: "other"
        ))

        let life = SessionLifecycle(
            registry: SessionRegistry(), store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        let count = await life.closeOrchestrationSet(
            orchestratorChannelId: "orc-1", guildId: "g", actorId: "u",
            provisioner: prov, configStore: configStore
        )

        #expect(count == 1)
        #expect(await store.binding(channelId: "other-agent") != nil) // untouched — completion ④
        #expect(!prov.deleted.contains("other-agent"))
    }

    @Test func stopsModuleSessionsEvenWithoutProvisioner() async throws {
        let store = freshTempStore()
        let configStore = try await orchestrationConfigStore(
            guildId: "g", orchestratorChannelId: "orc-1", categoryId: "cat-1"
        )
        try await store.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))
        let life = SessionLifecycle(
            registry: SessionRegistry(), store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )
        let count = await life.closeOrchestrationSet(
            orchestratorChannelId: "orc-1", guildId: "g", actorId: "u",
            provisioner: nil, configStore: configStore
        )
        #expect(count == 1)
        #expect(await store.binding(channelId: "agent-core") == nil)
    }

    // `/orchestration` re-run on a channel that is already a lead: the previous run's module
    // channels go, but the category stays because this run is about to reuse it.
    @Test func stopOrchestrationModulesLeavesCategoryAndConfigEntryIntact() async throws {
        let store = freshTempStore()
        let configStore = try await orchestrationConfigStore(
            guildId: "g", orchestratorChannelId: "orc-1", categoryId: "cat-1"
        )
        let prov = OrchestrationCloseFakeProvisioner(guildId: "g")
        prov.seed(id: "orc-1", parentId: "cat-1")
        prov.seed(id: "agent-core", parentId: "cat-1")
        try await store.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))
        let life = SessionLifecycle(
            registry: SessionRegistry(), store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        let closed = await life.stopOrchestrationModules(
            orchestratorChannelId: "orc-1", guildId: "g", actorId: "u", provisioner: prov
        )

        #expect(closed == ["agent-core"])
        #expect(await store.binding(channelId: "agent-core") == nil)
        #expect(prov.deleted == ["agent-core"])
        #expect(await configStore.loadServerConfig(guildId: "g")?.orchestration?["orc-1"]?.categoryId == "cat-1")
    }

    // `/clear` on a lead: modules keep their channel + binding but lose their context, and a
    // module belonging to another lead (or an archived one) is left alone.
    @Test func clearOrchestrationModulesWipesContextButKeepsBindings() async throws {
        let store = freshTempStore()
        let stopped = LockedBox<[String]>([])
        try await store.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, backendSessionId: "sid-core", cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))
        try await store.upsert(channelId: "agent-old", PersistedSession(
            backend: .claude, backendSessionId: "sid-old", cwd: "/repo/old", guildId: "g", updatedAt: "t",
            archived: true,
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "old"
        ))
        try await store.upsert(channelId: "other-agent", PersistedSession(
            backend: .claude, backendSessionId: "sid-other", cwd: "/repo/x", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-2", moduleName: "x"
        ))
        let life = SessionLifecycle(
            registry: SessionRegistry(), store: store, audit: tempAudit(),
            stopClaude: { ch in stopped.withLock { $0.append(ch) } }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        let cleared = await life.clearOrchestrationModules(orchestratorChannelId: "orc-1", actorId: "u")

        #expect(cleared == ["agent-core"])
        let core = await store.binding(channelId: "agent-core")
        #expect(core?.backendSessionId == nil)
        #expect(core?.orchestratorChannelId == "orc-1")  // binding kept, unlike stopOrchestrationModules
        #expect(core?.cwd == "/repo/core")
        #expect(stopped.withLock { $0 } == ["agent-core"])
        #expect(await store.binding(channelId: "agent-old")?.backendSessionId == "sid-old")
        #expect(await store.binding(channelId: "other-agent")?.backendSessionId == "sid-other")
    }

    // Promoting a module channel to a lead (`/orchestration` run inside it) must drop its old set
    // membership — otherwise the old lead's teardown/status still counts it as one of its modules.
    @Test func enableOrchestrationModeClearsPreviousModuleMembership() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "agent-core", PersistedSession(
            backend: .claude, cwd: "/repo/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "orc-1", moduleName: "core"
        ))
        let life = SessionLifecycle(
            registry: SessionRegistry(), store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        #expect(await life.enableOrchestrationMode(channelId: "agent-core", actorId: "u", guildId: "g") == true)

        let s = await store.binding(channelId: "agent-core")
        #expect(s?.orchestrationRole == "orchestrator")
        #expect(s?.orchestratorChannelId == nil)
        #expect(s?.moduleName == nil)
        // The old lead no longer sees it as one of its modules.
        let stillMine = await life.stopOrchestrationModules(
            orchestratorChannelId: "orc-1", guildId: "g", actorId: "u", provisioner: nil
        )
        #expect(stillMine.isEmpty)
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

@Suite("W11-d slash specs")
struct LiveSlashSpecTests {
    @Test func stopClearAndStopAllAreLeafCommands() {
        #expect(stopCommandSpec().subcommands.isEmpty)
        #expect(stopCommandSpec().options.isEmpty)
        #expect(clearCommandSpec().name == "clear")
        #expect(clearCommandSpec().subcommands.isEmpty)
        #expect(stopAllCommandSpec().name == "stop-all")
    }

    @Test func modelAndEffortHaveTopLevelValueOption() {
        let model = modelCommandSpec()
        #expect(model.name == "model")
        #expect(model.subcommands.isEmpty)
        #expect(model.options.map(\.name) == ["value"])
        #expect(model.options[0].required == true)
        #expect(model.options[0].choices.isEmpty)
        // G-P1-03: Discord autocomplete (not static choices).
        #expect(model.options[0].autocomplete == true)

        let effort = effortCommandSpec()
        #expect(effort.name == "effort")
        #expect(effort.options.map(\.name) == ["value"])
        #expect(effort.options[0].autocomplete == true)
        #expect(effort.options[0].choices.isEmpty)
    }

    @Test func modeHasBackendAndPermSubcommands() {
        let mode = modeCommandSpec()
        #expect(mode.name == "mode")
        #expect(mode.subcommands.map(\.name) == ["backend", "perm"])
        #expect(mode.subcommands[0].options.map(\.name) == ["backend"])
        #expect(mode.subcommands[1].options.map(\.name) == ["value"])
        #expect(Set(mode.subcommands[0].options[0].choices.map(\.value)) == Set(Backend.allCases.map(\.rawValue)))
    }

    @Test func agentHasStartCloseResumeStats() {
        let names = agentCommandSpec().subcommands.map(\.name)
        #expect(names == ["start", "close", "resume", "stats"])
    }

    @Test func allSpecsOrder() {
        // Relative order only: new commands may be inserted anywhere without
        // breaking this test, but these must stay in this order relative to each other.
        let expectedOrder = ["agent", "mode", "model", "effort", "stop", "clear", "stop-all", "setup", "doc", "config", "update"]
        let names = allSlashCommandSpecs().map(\.name)
        #expect(names.filter { expectedOrder.contains($0) } == expectedOrder)
    }

    @Test func docIsLeafWithPathOption() {
        let doc = docCommandSpec()
        #expect(doc.name == "doc")
        #expect(doc.subcommands.isEmpty)
        #expect(doc.options.map(\.name) == ["path"])
        #expect(doc.options[0].required == true)
    }
}

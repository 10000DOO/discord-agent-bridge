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
        ) == true)
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
        ) == true)
        #expect(await life.updateBinding(
            channelId: "c1", patch: BindingPatch(effort: "high"),
            actorId: "u", guildId: "g"
        ) == true)
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
        ) == true)
        #expect(live.withLock { $0 } == 0)
        #expect(await store.binding(channelId: "c1")?.model == "gpt-5")
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
        ) == true)
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
        ) == true)
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
        let names = allSlashCommandSpecs().map(\.name)
        #expect(names == ["agent", "mode", "model", "effort", "stop", "clear", "stop-all", "setup", "doc", "config", "update"])
    }

    @Test func docIsLeafWithPathOption() {
        let doc = docCommandSpec()
        #expect(doc.name == "doc")
        #expect(doc.subcommands.isEmpty)
        #expect(doc.options.map(\.name) == ["path"])
        #expect(doc.options[0].required == true)
    }
}

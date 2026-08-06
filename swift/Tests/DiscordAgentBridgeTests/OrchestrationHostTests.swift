import Testing
import Foundation
@testable import DiscordAgentBridge

// WO-4 (design_orchestration_module_agents.md): pure judgment (resolveWorkspaceRoot /
// validateModulePath / moduleSessionConfig) + the OrchestrationHost actor's 7 OrchestrationDecision
// cases. No Discord dependency anywhere — the two Discord-crossing seams (`runInjectedTurn`,
// `provisionerFactory`) are fakes injected at construction (mirrors SessionLifecycleTests.swift's
// style: build a fresh instance per test rather than mutating `.shared`).

// MARK: - Test support

private func tempConfigStore() -> ConfigStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-orch-host-cfg-\(UUID().uuidString)", isDirectory: true)
    return ConfigStore(baseDir: dir)
}

private func tempAudit() -> AuditLog {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-orch-host-audit-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("audit.jsonl", isDirectory: false)
    return AuditLog(fileURL: url, now: { "T" })
}

/// `OrchestrationHost`'s default `lifecycle: SessionLifecycle = .shared` would otherwise write
/// `startModuleAgentChannel`'s binding into the REAL `SessionStore.shared` instead of a test's
/// isolated `store` — this wires a `SessionLifecycle` onto the same fake `store` so `order`'s own
/// reads and `startModuleAgentChannel`'s write agree.
private func lifecycleFor(_ store: SessionStore) -> SessionLifecycle {
    SessionLifecycle(registry: SessionRegistry(), store: store, audit: tempAudit())
}

private func tempDir(_ name: String = UUID().uuidString) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dab-orch-host-\(name)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Minimal fake — only `createTextChannel` is exercised by `order`'s create-on-first-order path.
private final class FakeProvisioner: GuildChannelProvisioner, @unchecked Sendable {
    let guildId: String
    private(set) var createdNames: [String] = []
    private var seq = 0
    init(guildId: String = "g1") { self.guildId = guildId }

    func canManageChannels() async -> Bool { true }
    func channelExists(_ id: String) async -> Bool { true }
    func ensureCategory(name: String, existingId: String?) async throws -> ProvisionedChannel {
        fatalError("unused by OrchestrationHost.order")
    }
    func ensureTextChannel(name: String, parentId: String, existingId: String?) async throws -> ProvisionedChannel {
        fatalError("unused by OrchestrationHost.order")
    }
    func createTextChannel(name: String, parentId: String?) async throws -> ProvisionedChannel {
        seq += 1
        createdNames.append(name)
        return ProvisionedChannel(id: "mod-chan-\(seq)", name: name)
    }
    func renameChannel(id: String, name: String) async throws {}
    func setParent(id: String, parentId: String) async throws {}
    func deleteChannel(id: String) async throws {}
    func childChannelIds(categoryId: String) async -> [String] { [] }
}

/// Records every `runInjectedTurn`-shaped call the host fires. `order`/`report` now await this
/// (the prompt-post confirmation, not the turn itself), so a call is recorded before they return —
/// no `waitUntil` needed anymore, unlike the turn itself in production.
private final class TurnRecorder: @unchecked Sendable {
    struct Call: Equatable { let channelId: String; let guildId: String; let text: String }
    private let box = LockedBox<[Call]>([])
    /// Simulates the prompt post's own success/failure (`RunInjectedTurnFn`'s return value).
    var deliverResult = true
    var calls: [Call] { box.withLock { $0 } }
    func handler() -> OrchestrationHost.RunInjectedTurnFn {
        { channelId, guildId, _, text, _, _, _, _ in
            self.box.withLock { $0.append(Call(channelId: channelId, guildId: guildId, text: text)) }
            return self.deliverResult
        }
    }
}

private func leadSession(cwd: String, guildId: String = "g1") -> PersistedSession {
    PersistedSession(
        backend: .claude, cwd: cwd, guildId: guildId, ownerId: "owner-1", model: "sonnet", effort: "medium",
        permMode: "acceptEdits", updatedAt: "t", orchestrationRole: "orchestrator"
    )
}

private func agentSession(cwd: String, orchestratorChannelId: String, moduleName: String, guildId: String = "g1", backendSessionId: String? = nil) -> PersistedSession {
    PersistedSession(
        backend: .claude, backendSessionId: backendSessionId, cwd: cwd, guildId: guildId, updatedAt: "t",
        orchestrationRole: "agent", orchestratorChannelId: orchestratorChannelId, moduleName: moduleName
    )
}

// MARK: - resolveWorkspaceRoot (D12 home/root narrowing)

@Suite("resolveWorkspaceRoot")
struct ResolveWorkspaceRootTests {
    @Test func defaultsToParentOfProjectCwd() {
        #expect(resolveWorkspaceRoot(projectCwd: "/Users/x/proj", configured: nil, homeDir: "/Users/y") == "/Users/x")
    }

    @Test func narrowsToProjectCwdWhenParentIsHome() {
        #expect(resolveWorkspaceRoot(projectCwd: "/Users/x/proj", configured: nil, homeDir: "/Users/x") == "/Users/x/proj")
    }

    @Test func narrowsToProjectCwdWhenParentIsHomeWithTrailingSlash() {
        #expect(resolveWorkspaceRoot(projectCwd: "/Users/x/proj", configured: nil, homeDir: "/Users/x/") == "/Users/x/proj")
    }

    @Test func narrowsToProjectCwdWhenParentIsFilesystemRoot() {
        #expect(resolveWorkspaceRoot(projectCwd: "/proj", configured: nil, homeDir: "/Users/x") == "/proj")
    }

    @Test func configuredOverrideWinsRegardlessOfHomeOrRoot() {
        #expect(
            resolveWorkspaceRoot(projectCwd: "/Users/x/proj", configured: "/custom/root", homeDir: "/Users/x")
                == "/custom/root"
        )
    }
}

// MARK: - validateModulePath (R6, incl. symlink escape)

@Suite("validateModulePath")
struct ValidateModulePathTests {
    @Test func acceptsExistingDirectoryInsideRoot() {
        let root = tempDir("root")
        let module = root.appendingPathComponent("core", isDirectory: true)
        try? FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        #expect(validateModulePath(module.path, workspaceRoot: root.path))
    }

    @Test func rejectsPathOutsideRoot() {
        let root = tempDir("root2")
        #expect(!validateModulePath("/etc", workspaceRoot: root.path))
    }

    @Test func rejectsNonDirectory() {
        let root = tempDir("root3")
        let file = root.appendingPathComponent("f.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        #expect(!validateModulePath(file.path, workspaceRoot: root.path))
    }

    @Test func rejectsSymlinkEscapingRoot() {
        let root = tempDir("root4")
        let outside = tempDir("outside4")
        let link = root.appendingPathComponent("escape")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!validateModulePath(link.path, workspaceRoot: root.path))
    }
}

// MARK: - moduleSessionConfig (WO-4 step 6 priority table)

@Suite("moduleSessionConfig")
struct ModuleSessionConfigTests {
    @Test func setValuesWinForModelAndEffort() {
        let config = moduleSessionConfig(
            set: OrchestrationSet(categoryId: "cat-1", moduleModel: "haiku", moduleEffort: "low"),
            orchestratorBinding: SessionConfig(backend: .claude, model: "opus", effort: "high", permMode: "plan")
        )
        #expect(config.model == "haiku")
        #expect(config.effort == "low")
        #expect(config.permMode == "plan")
        #expect(config.backend == .claude)
    }

    @Test func fallsBackToOrchestratorBindingWhenSetValuesAreNil() {
        let config = moduleSessionConfig(
            set: OrchestrationSet(categoryId: "cat-1"),
            orchestratorBinding: SessionConfig(backend: .claude, model: "opus", effort: "high", permMode: "plan")
        )
        #expect(config.model == "opus")
        #expect(config.effort == "high")
    }

    @Test func nilSetFallsBackEntirely() {
        let config = moduleSessionConfig(
            set: nil,
            orchestratorBinding: SessionConfig(backend: .claude, model: "opus", effort: "high", permMode: "default")
        )
        #expect(config.model == "opus")
        #expect(config.effort == "high")
        #expect(config.permMode == "default")
    }
}

// MARK: - OrchestrationHost.order / .report — the 7 OrchestrationDecision cases

@Suite("OrchestrationHost")
struct OrchestrationHostTests {
    @Test func orderNotFoundWhenCallerHasNoBinding() async {
        let host = OrchestrationHost(store: freshTempStore(), configStore: tempConfigStore())
        let decision = await host.order(fromChannelId: "unbound", module: "core", path: "/tmp", text: "go")
        #expect(decision == .notFound)
    }

    @Test func orderWrongRoleWhenCallerIsNotOrchestrator() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "c1", agentSession(cwd: "/tmp", orchestratorChannelId: "lead", moduleName: "core"))
        let host = OrchestrationHost(store: store, configStore: tempConfigStore())
        let decision = await host.order(fromChannelId: "c1", module: "core", path: "/tmp", text: "go")
        #expect(decision == .wrongRole)
    }

    @Test func orderOutsideWorkspaceMessageIncludesConfigKeyAndValue() async throws {
        let store = freshTempStore()
        let projectDir = tempDir("project-a")
        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        let host = OrchestrationHost(store: store, configStore: tempConfigStore())

        let decision = await host.order(fromChannelId: "lead", module: "core", path: "/etc", text: "go")
        guard case .outsideWorkspace(let message) = decision else {
            Issue.record("expected .outsideWorkspace, got \(decision)")
            return
        }
        let expectedRoot = projectDir.deletingLastPathComponent().path
        #expect(message.contains("orchestration.workspaceRoot"))
        #expect(message.contains(expectedRoot))
    }

    @Test func orderConcurrencyLimit() async throws {
        let store = freshTempStore()
        let configStore = tempConfigStore()
        let projectDir = tempDir("project-b")
        let modulePath = projectDir.appendingPathComponent("core", isDirectory: true)
        try FileManager.default.createDirectory(at: modulePath, withIntermediateDirectories: true)

        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        // One already-active module under a DIFFERENT name, so the lookup-by-name in step 5
        // still has to create a new channel — the count check (step 3) must fire first.
        try await store.upsert(channelId: "other-mod", agentSession(cwd: "/tmp", orchestratorChannelId: "lead", moduleName: "other"))
        try await configStore.saveServerConfig(ServerConfig(
            guildId: "g1", orchestrationRuntime: OrchestrationRuntimeSection(maxConcurrentAgents: 1)
        ))

        let host = OrchestrationHost(store: store, configStore: configStore)
        let decision = await host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "go")
        #expect(decision == .concurrencyLimit(max: 1))
    }

    /// Review finding #2: an already-open module must be reused even once the lead is AT the
    /// concurrency cap — the cap bounds how many NEW module channels can be opened, it must not
    /// also block re-sending to one that already exists (R3 "이미 있으면 재사용").
    @Test func orderReusesExistingModuleEvenAtConcurrencyCap() async throws {
        let store = freshTempStore()
        let configStore = tempConfigStore()
        let projectDir = tempDir("project-reuse-at-cap")
        let modulePath = projectDir.appendingPathComponent("core", isDirectory: true)
        try FileManager.default.createDirectory(at: modulePath, withIntermediateDirectories: true)

        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        // backendSessionId set: the module still holds the context its first turn established, so
        // no role preamble is due (see orderReAddsRolePreambleAfterModuleContextCleared).
        try await store.upsert(channelId: "mod", agentSession(cwd: modulePath.path, orchestratorChannelId: "lead", moduleName: "core", backendSessionId: "sid-core"))
        try await configStore.saveServerConfig(ServerConfig(
            // One module already active, cap is exactly 1 — a NEW module would be refused, but
            // re-ordering the SAME ("core") module must still go through.
            guildId: "g1", orchestrationRuntime: OrchestrationRuntimeSection(maxConcurrentAgents: 1)
        ))

        let recorder = TurnRecorder()
        let host = OrchestrationHost(
            store: store, configStore: configStore, isTurnRunning: { _ in false }, runInjectedTurn: recorder.handler()
        )
        let decision = await host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "again")
        #expect(decision == .ok(channelId: "mod"))
        // `order` awaits the prompt-post confirmation before returning — already recorded. The
        // report reminder is appended to every order text, reused channel included.
        #expect(recorder.calls.contains { $0.channelId == "mod" && $0.text == "again" + orderReportReminder })
    }

    /// A module whose context was wiped (`/clear` on the module or on its lead) keeps its
    /// channel, so `order` reuses it — but the fresh session never saw the role doc, so the
    /// preamble must go out again or it answers in-channel and never calls `report`.
    @Test func orderReAddsRolePreambleAfterModuleContextCleared() async throws {
        let store = freshTempStore()
        let configStore = tempConfigStore()
        let projectDir = tempDir("project-cleared-module")
        let modulePath = projectDir.appendingPathComponent("core", isDirectory: true)
        try FileManager.default.createDirectory(at: modulePath, withIntermediateDirectories: true)

        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        // backendSessionId nil == cleared context.
        try await store.upsert(channelId: "mod", agentSession(cwd: modulePath.path, orchestratorChannelId: "lead", moduleName: "core"))

        let recorder = TurnRecorder()
        let host = OrchestrationHost(
            store: store, configStore: configStore, isTurnRunning: { _ in false }, runInjectedTurn: recorder.handler()
        )
        let decision = await host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "again")
        #expect(decision == .ok(channelId: "mod"))
        #expect(recorder.calls.contains {
            $0.channelId == "mod" && $0.text == "[역할] Agent:core\n\nagain" + orderReportReminder
        })
    }

    /// Review finding #1 (TOCTOU): two `order()` calls for two DIFFERENT new modules, racing
    /// concurrently against a cap of 1, must not both succeed. Before the fix, both could read the
    /// same pre-creation count from `store.all()` and both pass the check; the synchronous
    /// `pendingModuleCreations` reservation closes that window regardless of scheduling order —
    /// this test is deterministic, not timing-dependent, because it asserts the invariant (exactly
    /// one winner) rather than which one wins.
    @Test func orderConcurrentDoubleOrderDoesNotExceedConcurrencyCap() async throws {
        let store = freshTempStore()
        let configStore = tempConfigStore()
        let projectDir = tempDir("project-race")
        let corePath = projectDir.appendingPathComponent("core", isDirectory: true)
        let uiPath = projectDir.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: corePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: uiPath, withIntermediateDirectories: true)

        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        try await configStore.saveServerConfig(ServerConfig(
            guildId: "g1", orchestration: ["lead": OrchestrationSet(categoryId: "cat-1")],
            orchestrationRuntime: OrchestrationRuntimeSection(maxConcurrentAgents: 1)
        ))

        let host = OrchestrationHost(
            store: store, configStore: configStore, lifecycle: lifecycleFor(store), isTurnRunning: { _ in false },
            runInjectedTurn: { _, _, _, _, _, _, _, _ in true }, provisionerFactory: { _ in FakeProvisioner() }
        )

        async let first = host.order(fromChannelId: "lead", module: "core", path: corePath.path, text: "go")
        async let second = host.order(fromChannelId: "lead", module: "ui", path: uiPath.path, text: "go")
        let results = await [first, second]

        let okCount = results.filter { if case .ok = $0 { return true }; return false }.count
        let limitCount = results.filter { $0 == .concurrencyLimit(max: 1) }.count
        #expect(okCount == 1)
        #expect(limitCount == 1)
    }

    /// Re-review finding #1 (High): the previous fix only capped the TOTAL count per lead — it
    /// didn't remember WHICH module name was mid-creation, so two concurrent orders for the SAME
    /// new module name could still both pass the cap and both call `createModuleAgentChannel`,
    /// creating two channels for one module. `pendingModuleCreations` must catch this: exactly one
    /// call creates a channel and gets `.ok`, the other is refused `.busy` (not `.concurrencyLimit`
    /// — this is same-module contention, not "too many distinct modules").
    @Test func orderConcurrentSameModuleDoubleOrderCreatesExactlyOneChannel() async throws {
        let store = freshTempStore()
        let configStore = tempConfigStore()
        let projectDir = tempDir("project-same-module-race")
        let modulePath = projectDir.appendingPathComponent("core", isDirectory: true)
        try FileManager.default.createDirectory(at: modulePath, withIntermediateDirectories: true)

        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        try await configStore.saveServerConfig(ServerConfig(
            guildId: "g1", orchestration: ["lead": OrchestrationSet(categoryId: "cat-1")]
            // No orchestrationRuntime override — default cap (3) is nowhere near the bottleneck
            // here; the thing under test is same-name de-duplication, not the count cap.
        ))

        let provisioner = FakeProvisioner()
        let host = OrchestrationHost(
            store: store, configStore: configStore, lifecycle: lifecycleFor(store), isTurnRunning: { _ in false },
            runInjectedTurn: { _, _, _, _, _, _, _, _ in true }, provisionerFactory: { _ in provisioner }
        )

        async let first = host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "go")
        async let second = host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "go")
        let results = await [first, second]

        let okCount = results.filter { if case .ok = $0 { return true }; return false }.count
        let busyCount = results.filter { $0 == .busy }.count
        // Interleaving isn't fixed: if the scheduler runs the two calls back-to-back without
        // overlap, the second sees "core" already persisted and legitimately reuses it (R3) —
        // that's ok+ok, not ok+busy. Both outcomes are safe; only assert the shape, not which one.
        #expect(okCount + busyCount == 2)
        #expect(okCount >= 1)   // both refused would be a real bug
        // The invariant that must hold regardless of interleaving: exactly one channel (and one
        // session), never two, gets created for "core".
        #expect(provisioner.createdNames.count == 1)
        #expect(provisioner.createdNames[0].hasSuffix("-core-agent"))
        let moduleSessions = await store.all().values.filter { $0.orchestrationRole == "agent" && $0.moduleName == "core" }
        #expect(moduleSessions.count == 1)
    }

    @Test func orderRoundTripLimit() async throws {
        let store = freshTempStore()
        let configStore = tempConfigStore()
        let projectDir = tempDir("project-c")
        let modulePath = projectDir.appendingPathComponent("core", isDirectory: true)
        try FileManager.default.createDirectory(at: modulePath, withIntermediateDirectories: true)

        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        try await store.upsert(channelId: "mod", agentSession(cwd: modulePath.path, orchestratorChannelId: "lead", moduleName: "core"))
        try await configStore.saveServerConfig(ServerConfig(
            guildId: "g1", orchestrationRuntime: OrchestrationRuntimeSection(maxRoundTrips: 1)
        ))

        let recorder = TurnRecorder()
        let host = OrchestrationHost(store: store, configStore: configStore, runInjectedTurn: recorder.handler())
        // One report drives the round-trip counter for "lead" to 1 (== the configured max).
        let reportDecision = await host.report(fromChannelId: "mod", text: "done")
        #expect(reportDecision == .ok(channelId: "lead"))

        let decision = await host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "go again")
        #expect(decision == .roundTripLimit(max: 1))

        // `/agent close` and `/orchestration` re-run both give the lead a fresh session, so the
        // tally must go with it — otherwise the cap outlives the run that filled it and only a
        // process restart clears it.
        await host.resetRoundTrips(orchestratorChannelId: "lead")
        let afterReset = await host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "go again")
        #expect(afterReset == .ok(channelId: "mod"))
    }

    @Test func orderBusyWhenTargetModuleChannelIsAlreadyRunning() async throws {
        let store = freshTempStore()
        let configStore = tempConfigStore()
        let projectDir = tempDir("project-d")
        let modulePath = projectDir.appendingPathComponent("core", isDirectory: true)
        try FileManager.default.createDirectory(at: modulePath, withIntermediateDirectories: true)

        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        try await store.upsert(channelId: "mod", agentSession(cwd: modulePath.path, orchestratorChannelId: "lead", moduleName: "core"))

        let host = OrchestrationHost(
            store: store, configStore: configStore,
            isTurnRunning: { channelId in channelId == "mod" }
        )
        let decision = await host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "go")
        #expect(decision == .busy)
    }

    @Test func orderOkCreatesModuleChannelBindsSessionAndFiresTurn() async throws {
        let store = freshTempStore()
        let configStore = tempConfigStore()
        let projectDir = tempDir("project-e")
        let modulePath = projectDir.appendingPathComponent("core", isDirectory: true)
        try FileManager.default.createDirectory(at: modulePath, withIntermediateDirectories: true)

        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        try await configStore.saveServerConfig(ServerConfig(
            guildId: "g1", orchestration: ["lead": OrchestrationSet(categoryId: "cat-1", moduleModel: "haiku")]
        ))

        let recorder = TurnRecorder()
        let host = OrchestrationHost(
            store: store, configStore: configStore, lifecycle: lifecycleFor(store), isTurnRunning: { _ in false },
            runInjectedTurn: recorder.handler(), provisionerFactory: { _ in FakeProvisioner() }
        )

        let decision = await host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "implement it")
        guard case .ok(let channelId) = decision else {
            Issue.record("expected .ok, got \(decision)")
            return
        }
        let bound = await store.binding(channelId: channelId)
        #expect(bound?.orchestrationRole == "agent")
        #expect(bound?.orchestratorChannelId == "lead")
        #expect(bound?.moduleName == "core")
        #expect(bound?.model == "haiku")

        // New module channel's first turn must carry the "[역할] Agent:{module}" preamble
        // (OrchestrationHost.swift order()) so the fresh session learns its role, plus the
        // report reminder appended to every order text. `order` now awaits the prompt-post
        // confirmation before returning, so the call is already recorded.
        #expect(recorder.calls.contains {
            $0.channelId == channelId && $0.text == "[역할] Agent:core\n\nimplement it" + orderReportReminder
        })
    }

    @Test func orderDeliveryFailedWhenPromptPostFails() async throws {
        let store = freshTempStore()
        let configStore = tempConfigStore()
        let projectDir = tempDir("project-f")
        let modulePath = projectDir.appendingPathComponent("core", isDirectory: true)
        try FileManager.default.createDirectory(at: modulePath, withIntermediateDirectories: true)

        try await store.upsert(channelId: "lead", leadSession(cwd: projectDir.path))
        try await configStore.saveServerConfig(ServerConfig(
            guildId: "g1", orchestration: ["lead": OrchestrationSet(categoryId: "cat-1")]
        ))

        let recorder = TurnRecorder()
        recorder.deliverResult = false
        let host = OrchestrationHost(
            store: store, configStore: configStore, lifecycle: lifecycleFor(store), isTurnRunning: { _ in false },
            runInjectedTurn: recorder.handler(), provisionerFactory: { _ in FakeProvisioner() }
        )

        let decision = await host.order(fromChannelId: "lead", module: "core", path: modulePath.path, text: "go")
        #expect(decision == .deliveryFailed)
    }

    @Test func reportNotFoundWhenCallerHasNoBinding() async {
        let host = OrchestrationHost(store: freshTempStore(), configStore: tempConfigStore())
        let decision = await host.report(fromChannelId: "unbound", text: "done")
        #expect(decision == .notFound)
    }

    @Test func reportWrongRoleWhenCallerIsOrchestrator() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "lead", leadSession(cwd: "/tmp"))
        let host = OrchestrationHost(store: store, configStore: tempConfigStore())
        let decision = await host.report(fromChannelId: "lead", text: "done")
        #expect(decision == .wrongRole)
    }

    @Test func reportNotFoundWhenLeadBindingIsGone() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "mod", agentSession(cwd: "/tmp", orchestratorChannelId: "gone-lead", moduleName: "core"))
        let host = OrchestrationHost(store: store, configStore: tempConfigStore())
        let decision = await host.report(fromChannelId: "mod", text: "done")
        #expect(decision == .notFound)
    }

    @Test func reportOkRoutesOnlyToOwnOrchestratorChannelAndFiresTurn() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "lead", leadSession(cwd: "/tmp"))
        try await store.upsert(channelId: "mod", agentSession(cwd: "/tmp/core", orchestratorChannelId: "lead", moduleName: "core"))

        let recorder = TurnRecorder()
        let host = OrchestrationHost(store: store, configStore: tempConfigStore(), runInjectedTurn: recorder.handler())

        let decision = await host.report(fromChannelId: "mod", text: "DONE: implemented")
        #expect(decision == .ok(channelId: "lead"))
        // `report` now awaits the prompt-post confirmation before returning, so the call is
        // already recorded — no polling needed.
        #expect(recorder.calls.contains { $0.channelId == "lead" && $0.text == "DONE: implemented" })
    }

    @Test func reportDeliveryFailedWhenPromptPostFails() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "lead", leadSession(cwd: "/tmp"))
        try await store.upsert(channelId: "mod", agentSession(cwd: "/tmp/core", orchestratorChannelId: "lead", moduleName: "core"))

        let recorder = TurnRecorder()
        recorder.deliverResult = false
        let host = OrchestrationHost(store: store, configStore: tempConfigStore(), runInjectedTurn: recorder.handler())

        let decision = await host.report(fromChannelId: "mod", text: "DONE: implemented")
        #expect(decision == .deliveryFailed)
    }

    @Test func reportBusyWhenOrchestratorChannelIsAlreadyRunning() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "lead", leadSession(cwd: "/tmp"))
        try await store.upsert(channelId: "mod", agentSession(cwd: "/tmp/core", orchestratorChannelId: "lead", moduleName: "core"))

        let host = OrchestrationHost(
            store: store, configStore: tempConfigStore(),
            isTurnRunning: { channelId in channelId == "lead" }
        )
        let decision = await host.report(fromChannelId: "mod", text: "DONE: implemented")
        #expect(decision == .busy)
    }

    @Test func autoReportIfMissingNoOpsForNonAgentChannel() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "lead", leadSession(cwd: "/tmp"))

        let recorder = TurnRecorder()
        let host = OrchestrationHost(store: store, configStore: tempConfigStore(), runInjectedTurn: recorder.handler())

        await host.autoReportIfMissing(channelId: "lead", text: "some answer")
        #expect(recorder.calls.isEmpty)
    }

    @Test func autoReportIfMissingForwardsWhenModuleNeverCalledReport() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "lead", leadSession(cwd: "/tmp"))
        try await store.upsert(channelId: "mod", agentSession(cwd: "/tmp/core", orchestratorChannelId: "lead", moduleName: "core"))

        let recorder = TurnRecorder()
        let host = OrchestrationHost(store: store, configStore: tempConfigStore(), runInjectedTurn: recorder.handler())

        // Module finished its turn without ever calling `report()`.
        await host.autoReportIfMissing(channelId: "mod", text: "trivial fix done")
        #expect(recorder.calls.contains { $0.channelId == "lead" && $0.text == "trivial fix done" })
    }

    @Test func autoReportIfMissingSkipsWhenModuleAlreadyReportedThisTurn() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "lead", leadSession(cwd: "/tmp"))
        try await store.upsert(channelId: "mod", agentSession(cwd: "/tmp/core", orchestratorChannelId: "lead", moduleName: "core"))

        let recorder = TurnRecorder()
        let host = OrchestrationHost(store: store, configStore: tempConfigStore(), runInjectedTurn: recorder.handler())

        let decision = await host.report(fromChannelId: "mod", text: "DONE: implemented")
        #expect(decision == .ok(channelId: "lead"))

        // The turn's own completion hook runs after — must not forward a second, redundant report.
        await host.autoReportIfMissing(channelId: "mod", text: "DONE: implemented")
        #expect(recorder.calls.count == 1)
    }
}

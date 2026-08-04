import Foundation

// WO-4 (design_orchestration_module_agents.md): decides what actually happens when the lead
// session orders a module, or a module reports back to its lead. Judgment (role/path/limits) is
// pure free functions below so R4/R6/R7 are unit-testable without any Discord dependency; the
// actor adds the I/O (store/config lookups) plus the two side effects the library cannot perform
// itself — creating a Discord channel and firing a bot-authored turn both require DiscordBM types
// that only exist in the `dab` executable target (see `OrchestrationHost`'s doc comment below).

private let log = Logger(name: "orchestration-host")

/// Outcome of `OrchestrationHost.order` / `.report` (R3/R4/R6/R7).
public enum OrchestrationDecision: Sendable, Equatable {
    case ok(channelId: String)
    /// The target channel is already mid-turn. No queue (8장 4번) — the caller decides whether
    /// to retry, matching R7's "즉시 반환" requirement instead of silently queuing behind the
    /// existing turn the way `DabSessionBridge.runTurn`'s own per-channel gate would.
    case busy
    /// R6 rejection. The associated string already names the config key AND the value in effect
    /// (e.g. `"orchestration.workspaceRoot=/Users/x/proj"`) so a relayed refusal is self-explanatory.
    case outsideWorkspace(root: String)
    case concurrencyLimit(max: Int)
    case roundTripLimit(max: Int)
    /// R4: the calling channel's role doesn't match the tool (module called `send_order`, or the
    /// lead called `report`).
    case wrongRole
    /// No session binding at all for the calling channel, or (for `report`) the lead channel it
    /// points at is gone. Also the fallback when a module channel cannot be created/found.
    case notFound
}

// MARK: - Pure judgment (no I/O) — WO-4's primary unit-test target.

/// Default confinement root = `projectCwd`'s parent, unless `configured` overrides it, or the
/// computed parent is the home directory / filesystem root (D12 — narrowed back to `projectCwd`).
public func resolveWorkspaceRoot(projectCwd: String, configured: String?, homeDir: String) -> String {
    if let configured, !configured.isEmpty { return configured }
    let parent = (projectCwd as NSString).deletingLastPathComponent
    if isHomeOrFilesystemRoot(parent, homeDir: homeDir) {
        log.warn(
            "orchestration.workspaceRoot default (\(parent)) is the home/filesystem root — "
                + "narrowed to project folder \(projectCwd); set orchestration.workspaceRoot to widen it"
        )
        return projectCwd
    }
    return parent
}

private func isHomeOrFilesystemRoot(_ path: String, homeDir: String) -> Bool {
    if path.isEmpty || path == "/" { return true }
    return dropTrailingSlash(path) == dropTrailingSlash(homeDir)
}

private func dropTrailingSlash(_ path: String) -> String {
    var s = path
    while s.count > 1, s.hasSuffix("/") { s.removeLast() }
    return s
}

/// R6 confinement check for a module path — reuses `Confinement.swift`'s realpath + component
/// comparison (no new path logic), and additionally requires the resolved path to already be an
/// existing directory.
public func validateModulePath(_ path: String, workspaceRoot: String) -> Bool {
    let root = realpathOrResolve(workspaceRoot)
    let resolved = realpathOrResolve(path)
    guard isWithin(root: root, child: resolved) else { return false }
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) && isDir.boolValue
}

/// Module session `SessionConfig` assembly (WO-4 step 6) — pure. Priority: the set's start-card
/// value wins for `model`/`effort`; `permMode`/`backend` always inherit the lead channel's binding
/// (R10 — not a start-card field). `cwd` isn't part of `SessionConfig`; it is
/// `startModuleAgentChannel`'s own parameter, filled by the caller with the already-validated path.
///
/// R12 (module sessions are subagent-blocking targets too) is enforced by `SessionLifecycle.
/// startModuleAgentChannel` (WO-2), which hardcodes `orchestrationSession: true` directly on the
/// `PersistedSession` it writes — `SessionConfig` has no field for it, so there is nothing to
/// keep in sync here.
public func moduleSessionConfig(set: OrchestrationSet?, orchestratorBinding: SessionConfig) -> SessionConfig {
    SessionConfig(
        backend: orchestratorBinding.backend,
        model: set?.moduleModel ?? orchestratorBinding.model,
        effort: set?.moduleEffort ?? orchestratorBinding.effort,
        permMode: orchestratorBinding.permMode
    )
}

/// Model-facing text for an `OrchestrationDecision` (mirrors `shareResultText`'s shape,
/// `Grok/AttachGateway.swift:264` — a pure "(text, isError)" mapper) so the sidecar boundary
/// (WO-5) and its TS counterpart (WO-6) relay this sentence verbatim instead of inventing
/// wording per decision.
public func orchestrationDecisionText(_ decision: OrchestrationDecision) -> (text: String, isError: Bool) {
    switch decision {
    case .ok(let channelId):
        return ("Delivered to channel <#\(channelId)>.", false)
    case .busy:
        return ("Refused: the target channel is already running a turn. Try again shortly.", true)
    case .outsideWorkspace(let root):
        return ("Refused: the module path is outside the allowed workspace (\(root)).", true)
    case .concurrencyLimit(let max):
        return ("Refused: too many module sessions are already running (max \(max)).", true)
    case .roundTripLimit(let max):
        return ("Refused: this issue reached its order/report round-trip limit (max \(max)); a human needs to step in.", true)
    case .wrongRole:
        return ("Refused: this tool cannot be called from this channel's role.", true)
    case .notFound:
        return ("Refused: no matching orchestration session was found for this channel.", true)
    }
}

// MARK: - Host actor

/// Star-topology gateway between a lead ("orchestrator") channel and its module ("agent")
/// channels. `order`/`report` are the only entry points a session's MCP tool call can reach
/// (WO-5/6 wire the sidecar boundary onto them) — the tool names alone fix the direction (R4),
/// and this actor is where that direction is actually enforced.
///
/// Two dependencies (`runInjectedTurn` handler, channel-provisioner factory) have no production
/// default here: creating a Discord channel and posting a bot-authored turn both need DiscordBM
/// types that only exist in the `dab` executable target (this library has no DiscordBM
/// dependency — see `Package.swift`). They start nil and are wired once from `dab`'s boot (WO-5),
/// the same seam shape as `FileAttachHost.setAttachHandler` / `DocumentShareHost.setShareHandler`.
/// Every other dependency already has an in-library production default, so it is plain
/// constructor injection (mirrors `SessionLifecycle`) — tests build a fresh instance instead of
/// mutating `.shared`.
public actor OrchestrationHost {
    public static let shared = OrchestrationHost()

    /// Fire a bot-authored turn on `channelId` (mirrors `runInjectedTurn`'s parameter list minus
    /// `client`).
    public typealias RunInjectedTurnFn = @Sendable (
        _ channelId: String, _ guildId: String, _ backend: Backend, _ promptText: String,
        _ postPrompt: Bool, _ announceExtras: Bool, _ actorId: String, _ roleTier: String
    ) async -> Void

    /// Build a `GuildChannelProvisioner` for one guild (the concrete `DiscordGuildChannelProvisioner`
    /// lives in `dab`).
    public typealias ProvisionerFactory = @Sendable (_ guildId: String) -> any GuildChannelProvisioner

    private static let systemActorId = "system"
    private static let systemRoleTier = "execute"

    private let store: SessionStore
    private let configStore: ConfigStore
    private let lifecycle: SessionLifecycle
    private let isTurnRunning: @Sendable (String) async -> Bool
    private var runInjectedTurnFn: RunInjectedTurnFn?
    private var provisionerFactory: ProvisionerFactory?

    /// ponytail: in-memory only, keyed by lead channel id — resets on process restart and does
    /// not separate distinct issues handled back-to-back by the same lead channel. Ceiling: fine
    /// as long as a restart mid-issue is rare and re-hitting the cap after one is an acceptable
    /// (not silent) failure mode. Upgrade path if that ever matters: persist alongside
    /// `ServerConfig.orchestration[leadId]` and reset it in `closeOrchestrationSet` (WO-7) so it
    /// is scoped to one issue/set instead of the channel's entire lifetime.
    private var roundTripCounts: [String: Int] = [:]

    /// Module names currently mid-creation for a lead channel — not yet persisted to `store`.
    /// Closes two gaps `store.all()` alone can't (it's an `await` away, so two racing `order()`
    /// calls can otherwise both read the same pre-creation snapshot):
    ///  1. R7 concurrency cap — its size is added to `store.all()`'s existing-module count, so two
    ///     calls opening two DIFFERENT new modules can't both slip under the cap.
    ///  2. Same-module double order — a second `order()` for a module already in this set is
    ///     refused `.busy` instead of racing a second `createModuleAgentChannel` for the same name.
    /// Reserved (`insert`) and released (`remove`, via `defer`) around the single `await` that
    /// creates the channel — no `await` sits between the `.busy`/cap check and the reservation, so
    /// actor isolation makes that pair atomic. Mirrors `DabSessionBridge.turnDepth`'s
    /// reserve/release-to-nil shape (`Bridges/DabSessionBridge.swift:240,255-257`).
    private var pendingModuleCreations: [String: Set<String>] = [:]

    public init(
        store: SessionStore = .shared,
        configStore: ConfigStore = .shared,
        lifecycle: SessionLifecycle = .shared,
        isTurnRunning: @escaping @Sendable (String) async -> Bool = {
            await DabSessionBridge.shared.isTurnRunning(channelId: $0)
        },
        runInjectedTurn: RunInjectedTurnFn? = nil,
        provisionerFactory: ProvisionerFactory? = nil
    ) {
        self.store = store
        self.configStore = configStore
        self.lifecycle = lifecycle
        self.isTurnRunning = isTurnRunning
        self.runInjectedTurnFn = runInjectedTurn
        self.provisionerFactory = provisionerFactory
    }

    /// Wired once from `dab`'s boot (WO-5) — same shape as `FileAttachHost.setAttachHandler`.
    public func setRunTurnHandler(_ fn: @escaping RunInjectedTurnFn) { runInjectedTurnFn = fn }
    /// Wired once from `dab`'s boot (WO-5).
    public func setProvisionerFactory(_ fn: @escaping ProvisionerFactory) { provisionerFactory = fn }

    /// Lead → module. Creates the module channel + session on first order for that module name,
    /// reuses it after. Returns immediately once the turn has been fired (fire-and-forget — the
    /// lead must not block its own turn waiting on the module, 3-2 시퀀스 다이어그램 note).
    public func order(fromChannelId: String, module: String, path: String, text: String) async -> OrchestrationDecision {
        guard let lead = await store.binding(channelId: fromChannelId) else { return .notFound }
        guard lead.orchestrationRole == "orchestrator" else { return .wrongRole }

        let runtime = await configStore.loadServerConfig(guildId: lead.guildId)?.orchestrationRuntime
        let workspaceRoot = resolveWorkspaceRoot(
            projectCwd: lead.cwd, configured: runtime?.workspaceRoot, homeDir: NSHomeDirectory()
        )
        guard validateModulePath(path, workspaceRoot: workspaceRoot) else {
            return .outsideWorkspace(root: "orchestration.workspaceRoot=\(workspaceRoot)")
        }

        let maxRoundTrips = runtime?.maxRoundTrips ?? ConfigDefaults.orchestrationMaxRoundTrips
        guard (roundTripCounts[fromChannelId] ?? 0) < maxRoundTrips else { return .roundTripLimit(max: maxRoundTrips) }

        let allBindings = await store.all()
        let activeModules = allBindings.filter {
            !$0.value.archived && $0.value.orchestrationRole == "agent" && $0.value.orchestratorChannelId == fromChannelId
        }

        // R3: an already-open module is always reused, regardless of the concurrency cap below —
        // the cap exists to bound how many NEW sessions can be opened, not to block re-sending to
        // one that already exists (that ordering bug is what review finding #2 fixed).
        let moduleChannelId: String
        let isNewChannel: Bool
        if let existing = activeModules.first(where: { $0.value.moduleName == module }) {
            moduleChannelId = existing.key
            isNewChannel = false
        } else {
            // Same module already mid-creation from an earlier, still-in-flight `order()` call —
            // refuse rather than race a second `createModuleAgentChannel` for the same name.
            guard pendingModuleCreations[fromChannelId]?.contains(module) != true else { return .busy }

            let maxConcurrent = runtime?.maxConcurrentAgents ?? ConfigDefaults.orchestrationMaxConcurrentAgents
            let inFlight = pendingModuleCreations[fromChannelId]?.count ?? 0
            guard activeModules.count + inFlight < maxConcurrent else { return .concurrencyLimit(max: maxConcurrent) }

            pendingModuleCreations[fromChannelId, default: []].insert(module)
            defer {
                pendingModuleCreations[fromChannelId]?.remove(module)
                if pendingModuleCreations[fromChannelId]?.isEmpty == true { pendingModuleCreations[fromChannelId] = nil }
            }
            guard let created = await createNewModuleChannel(
                lead: lead, leadChannelId: fromChannelId, module: module, path: path
            ) else { return .notFound }
            moduleChannelId = created
            isNewChannel = true
        }

        if await isTurnRunning(moduleChannelId) { return .busy }
        guard let runTurn = runInjectedTurnFn else { return .notFound }
        // New module channel's first turn must carry the role preamble (CLAUDE.md's role table,
        // OrchestrationProjectBundle.swift) so the fresh session knows it's a module agent — a
        // reused channel's session already learned its role on its own first turn.
        let turnText = isNewChannel ? "[역할] Agent:\(module)\n\n\(text)" : text
        Task {
            await runTurn(
                moduleChannelId, lead.guildId, lead.backend, turnText,
                true, false, Self.systemActorId, Self.systemRoleTier
            )
        }
        return .ok(channelId: moduleChannelId)
    }

    /// Module → lead. Always routes to the caller's own `orchestratorChannelId` — no target
    /// argument exists, so a module cannot address anything but its own lead (R4 enforced by
    /// omission, not by a runtime check).
    public func report(fromChannelId: String, text: String) async -> OrchestrationDecision {
        guard let agent = await store.binding(channelId: fromChannelId) else { return .notFound }
        guard agent.orchestrationRole == "agent" else { return .wrongRole }
        guard let leadId = agent.orchestratorChannelId, let lead = await store.binding(channelId: leadId) else {
            return .notFound
        }

        roundTripCounts[leadId, default: 0] += 1

        guard let runTurn = runInjectedTurnFn else { return .notFound }
        Task {
            await runTurn(leadId, lead.guildId, lead.backend, text, true, false, Self.systemActorId, Self.systemRoleTier)
        }
        return .ok(channelId: leadId)
    }

    /// Create + bind a brand-new module channel (`order`'s not-yet-existing branch). Returns nil
    /// on any failure — missing provisioner/category, or `createModuleAgentChannel` throwing —
    /// and logs the reason in every case, so a refusal is never silent.
    private func createNewModuleChannel(
        lead: PersistedSession, leadChannelId: String, module: String, path: String
    ) async -> String? {
        guard let makeProvisioner = provisionerFactory else {
            log.warn("module channel creation skipped: no provisioner wired lead=\(leadChannelId) module=\(module)")
            return nil
        }
        let server = await configStore.loadServerConfig(guildId: lead.guildId)
        guard let categoryId = server?.orchestration?[leadChannelId]?.categoryId else {
            log.warn("module channel creation skipped: no orchestration category for lead=\(leadChannelId) module=\(module)")
            return nil
        }

        let created: ProvisionedChannel
        do {
            created = try await createModuleAgentChannel(
                provisioner: makeProvisioner(lead.guildId), moduleName: module, categoryId: categoryId
            )
        } catch {
            log.warn("module channel creation failed lead=\(leadChannelId) module=\(module) err=\(error)")
            return nil
        }

        let config = moduleSessionConfig(
            set: server?.orchestration?[leadChannelId], orchestratorBinding: sessionConfig(from: lead)
        )
        _ = await lifecycle.startModuleAgentChannel(
            channelId: created.id, guildId: lead.guildId, ownerId: lead.ownerId ?? "",
            cwd: path, moduleName: module, orchestratorChannelId: leadChannelId, config: config,
            actorId: Self.systemActorId, roleTier: Self.systemRoleTier
        )
        return created.id
    }
}

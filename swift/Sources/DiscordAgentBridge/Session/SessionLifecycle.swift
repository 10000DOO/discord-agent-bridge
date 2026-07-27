import Foundation

/// Outcome of `updateBinding` (C4-a/M11). TS `orchestrator.setModel`/`setEffort` collapse to
/// `'ok' | 'no-session' | 'unsupported' | 'error'`; this collapses to what this layer can tell
/// apart without touching the bridges. `DabMain` (WO-7) maps each case to a user-facing i18n key.
public enum BindingUpdateResult: Sendable, Equatable {
    /// Patch applied and persisted.
    case ok
    /// No registry/store binding for this channel (TS `router.noSession`).
    case noBinding
    /// `patch.effort` is set on a codex binding but is not a catalog-known value — nothing persisted.
    case invalidEffort
    /// Claude/`.custom` live session declined the model/effort switch — nothing persisted.
    case applyFailed
    /// The durable binding update failed, so registry/live lifecycle state was left unchanged.
    case persistFailed
}

/// Thin orchestration over the three bridges + SessionRegistry + SessionStore for stop /
/// interrupt / stopAll / clear / rebind / field updates (W14 + W11-d). Mirrors
/// `sessionOrchestrator.ts` stop/interrupt/stopAll + slash binding ops without pulling Discord
/// into the library. Bridges only drop live backend state; this type owns registry/store policy.
///
/// Injectable bridge callbacks keep unit tests off the shared singletons when needed; production
/// uses the default shared-bridge closures.
public struct SessionLifecycle: Sendable {
    public typealias ChannelOp = @Sendable (String) async -> Void
    public typealias InterruptOp = @Sendable (String) async -> Bool
    /// Live field switch on an open Claude session (`channelId`, `value`) → applied?
    public typealias LiveFieldOp = @Sendable (String, String) async -> Bool
    /// M11: is `value` a catalog-known codex effort level?
    public typealias EffortValidator = @Sendable (String) async -> Bool

    private let registry: SessionRegistry
    private let store: SessionStore
    private let audit: AuditLog
    private let stopClaude: ChannelOp
    private let stopCodex: ChannelOp
    private let stopGrok: ChannelOp
    private let interruptClaude: InterruptOp
    private let interruptCodex: InterruptOp
    private let interruptGrok: InterruptOp
    private let setModelClaude: LiveFieldOp
    private let setEffortClaude: LiveFieldOp
    private let isKnownCodexEffort: EffortValidator
    private let now: @Sendable () -> String

    public init(
        registry: SessionRegistry = .shared,
        store: SessionStore = .shared,
        audit: AuditLog = .shared,
        stopClaude: @escaping ChannelOp = { await DabSessionBridge.shared.stop(channelId: $0) },
        stopCodex: @escaping ChannelOp = { await CodexSessionBridge.shared.stop(channelId: $0) },
        stopGrok: @escaping ChannelOp = { await GrokSessionBridge.shared.stop(channelId: $0) },
        interruptClaude: @escaping InterruptOp = { await DabSessionBridge.shared.interrupt(channelId: $0) },
        interruptCodex: @escaping InterruptOp = { await CodexSessionBridge.shared.interrupt(channelId: $0) },
        interruptGrok: @escaping InterruptOp = { await GrokSessionBridge.shared.interrupt(channelId: $0) },
        setModelClaude: @escaping LiveFieldOp = {
            await DabSessionBridge.shared.setModel(channelId: $0, model: $1)
        },
        setEffortClaude: @escaping LiveFieldOp = {
            await DabSessionBridge.shared.setEffort(channelId: $0, effort: $1)
        },
        isKnownCodexEffort: @escaping EffortValidator = {
            await CodexConfigSource.shared.isKnownEffort($0)
        },
        // Default cannot call internal `iso8601Now` from a public default-arg expression.
        now: (@Sendable () -> String)? = nil
    ) {
        self.registry = registry
        self.store = store
        self.audit = audit
        self.stopClaude = stopClaude
        self.stopCodex = stopCodex
        self.stopGrok = stopGrok
        self.interruptClaude = interruptClaude
        self.interruptCodex = interruptCodex
        self.interruptGrok = interruptGrok
        self.setModelClaude = setModelClaude
        self.setEffortClaude = setEffortClaude
        self.isKnownCodexEffort = isKnownCodexEffort
        self.now = now ?? { iso8601Now() }
    }

    /// Process-wide default used by `dab` (same pattern as bridges/registry).
    public static let shared = SessionLifecycle()

    // MARK: - stop / interrupt / stopAll

    /// Hard-stop one channel: stop **every** backend bridge for this channelId (prefix/rebind can
    /// leave a non-bound backend live), then unbind registry + remove store. Idempotent when
    /// nothing is bound and all bridges are idle.
    @discardableResult
    public func stopChannel(
        channelId: String,
        actorId: String,
        guildId: String,
        roleTier: String = "execute"
    ) async -> Bool {
        let backend = await resolveBackend(channelId: channelId)
        let hadReg = await registry.binding(channelId: channelId) != nil
        let hadStore = await store.binding(channelId: channelId) != nil
        let hadBinding = hadReg || hadStore
        // Keep a durable binding if the removal cannot be written. Stopping first would make a
        // transient disk failure look like a completed close while the next boot resurrects it.
        if hadBinding {
            do {
                try await store.remove(channelId: channelId)
            } catch {
                return false
            }
        }
        // Always all three — binding/store may name the wrong backend or be empty while a
        // prefix-spawned process is still live (RV: process leak).
        await stopAllBridges(channelId: channelId)
        await registry.unbind(channelId: channelId)
        if hadBinding {
            await audit.record(AuditEntry(
                actorId: actorId,
                roleTier: roleTier,
                guildId: guildId,
                channelId: channelId,
                action: "stop",
                mode: backend?.rawValue,
                status: "ok"
            ))
        }
        return hadBinding
    }

    /// Cancel in-flight turns on **every** backend for this channel; keep registry/store.
    /// Returns whether any live backend reported a session (TS `orchestrator.interrupt`).
    public func interruptChannel(
        channelId: String,
        actorId: String,
        guildId: String,
        roleTier: String = "execute"
    ) async -> Bool {
        // Any-backend: prefix/rebind can leave a non-bound bridge as the live one.
        let claude = await interruptClaude(channelId)
        let codex = await interruptCodex(channelId)
        let grok = await interruptGrok(channelId)
        let ok = claude || codex || grok
        if ok {
            let mode: String?
            if claude { mode = Backend.claude.rawValue }
            else if codex { mode = Backend.codex.rawValue }
            else if grok { mode = Backend.grok.rawValue }
            else { mode = await resolveBackend(channelId: channelId)?.rawValue }
            await audit.record(AuditEntry(
                actorId: actorId,
                roleTier: roleTier,
                guildId: guildId,
                channelId: channelId,
                action: "interrupt",
                mode: mode,
                status: "ok"
            ))
        }
        return ok
    }

    /// Stop every bound channel (registry ∪ **active** store). Archived store rows are skipped
    /// (TS resumeAll / list consumers filter `archived`; stop itself hard-removes). Each stop is
    /// isolated so one failure does not abort the rest. Per-channel audit guildId prefers the
    /// store binding when present.
    public func stopAll(actorId: String, guildId: String, roleTier: String = "admin") async -> Int {
        var ids = Set(await registry.list().keys)
        let storeActive = await store.active()
        for key in storeActive.keys { ids.insert(key) }
        // guildId for audit: prefer any store row (incl. if only registry-bound).
        let storeAll = await store.all()
        for channelId in ids {
            let g = storeAll[channelId]?.guildId ?? guildId
            await stopChannel(channelId: channelId, actorId: actorId, guildId: g, roleTier: roleTier)
        }
        return ids.count
    }

    // MARK: - W11-d binding ops

    /// `/clear`: wipe `backendSessionId`, then stop live bridges; **keep** registry+store config
    /// (PLAN §14.6). Next turn fresh-starts with the same model/effort/perm/cwd.
    @discardableResult
    public func clearChannel(
        channelId: String,
        actorId: String,
        guildId: String,
        roleTier: String = "execute",
        defaultCwd: String = NSHomeDirectory()
    ) async -> Bool {
        guard var session = await resolveSession(
            channelId: channelId, guildId: guildId, defaultCwd: defaultCwd
        ) else { return false }

        session.backendSessionId = nil
        session.lifecycleGeneration = UUID().uuidString
        let startedAt = now()
        session.contextGenerationStartedAt = startedAt
        session.updatedAt = startedAt
        do {
            try await store.upsert(channelId: channelId, session)
        } catch {
            return false
        }
        await stopAllBridges(channelId: channelId)
        await registry.bind(channelId: channelId, sessionConfig(from: session))
        await audit.record(AuditEntry(
            actorId: actorId,
            roleTier: roleTier,
            guildId: guildId,
            channelId: channelId,
            action: "clear",
            mode: session.backend.rawValue,
            status: "ok"
        ))
        return true
    }

    /// `/mode backend` same-backend: persist then stop live, rebind to `backend` keeping cwd/owner; clear backendSessionId.
    /// Cross-backend drops model/effort (backend-specific); same-backend keeps them.
    /// Different-backend path from the slash command opens the reconfigure wizard instead (see
    /// `reconfigureBinding` for confirm).
    @discardableResult
    public func rebindBackend(
        channelId: String,
        backend: Backend,
        actorId: String,
        guildId: String,
        roleTier: String = "execute",
        defaultCwd: String = NSHomeDirectory()
    ) async -> Bool {
        guard var session = await resolveSession(
            channelId: channelId, guildId: guildId, defaultCwd: defaultCwd
        ) else { return false }

        let same = session.backend == backend
        session.backend = backend
        session.backendSessionId = nil
        session.lifecycleGeneration = UUID().uuidString
        if !same {
            session.model = nil
            session.effort = nil
        }
        let startedAt = now()
        session.contextGenerationStartedAt = startedAt
        session.updatedAt = startedAt
        do {
            try await store.upsert(channelId: channelId, session)
        } catch {
            return false
        }
        await stopAllBridges(channelId: channelId)
        await registry.bind(channelId: channelId, sessionConfig(from: session))
        await audit.record(AuditEntry(
            actorId: actorId,
            roleTier: roleTier,
            guildId: guildId,
            channelId: channelId,
            action: "mode.backend",
            mode: backend.rawValue,
            status: "ok"
        ))
        return true
    }

    /// Reconfigure confirm (TS `switchSession`): persist then stop live bridges, rebind **same channel** with
    /// the wizard-chosen backend/model/effort/perm. Keeps cwd/ownerId; clears backendSessionId
    /// (fresh context). Does not create a new channel.
    @discardableResult
    public func reconfigureBinding(
        channelId: String,
        backend: Backend,
        model: String?,
        effort: String?,
        permMode: String?,
        actorId: String,
        guildId: String,
        roleTier: String = "execute",
        defaultCwd: String = NSHomeDirectory()
    ) async -> Bool {
        guard var session = await resolveSession(
            channelId: channelId, guildId: guildId, defaultCwd: defaultCwd
        ) else { return false }

        session.backend = backend
        session.backendSessionId = nil
        session.lifecycleGeneration = UUID().uuidString
        session.model = model
        session.effort = effort
        if let permMode { session.permMode = permMode }
        let startedAt = now()
        session.contextGenerationStartedAt = startedAt
        session.updatedAt = startedAt
        do {
            try await store.upsert(channelId: channelId, session)
        } catch {
            return false
        }
        await stopAllBridges(channelId: channelId)
        await registry.bind(channelId: channelId, sessionConfig(from: session))
        await audit.record(AuditEntry(
            actorId: actorId,
            roleTier: roleTier,
            guildId: guildId,
            channelId: channelId,
            action: "mode.backend",
            mode: backend.rawValue,
            permMode: session.permMode,
            status: "ok"
        ))
        return true
    }

    /// Patch model/effort/permMode on registry+store without stopping the live session.
    /// C4-a: for Claude/`.custom`, a `model`/`effort` patch is applied to the live sidecar
    /// session FIRST (TS `orchestrator.setModel`/`setEffort`: try the live session, only persist
    /// on success) — a failed apply leaves the binding untouched and reports the failure instead
    /// of silently persisting anyway. M11: a codex `effort` patch must name a catalog-known value
    /// or nothing is persisted. Codex/Grok are otherwise binding-only (next ensure/turn picks up
    /// the new fields). Returns `.noBinding` when no binding exists (TS `router.noSession`).
    @discardableResult
    public func updateBinding(
        channelId: String,
        patch: BindingPatch,
        actorId: String,
        guildId: String,
        roleTier: String = "execute",
        defaultCwd: String = NSHomeDirectory()
    ) async -> BindingUpdateResult {
        guard var session = await resolveSession(
            channelId: channelId, guildId: guildId, defaultCwd: defaultCwd
        ) else { return .noBinding }

        // M11: validate before ever touching registry/store.
        if session.backend == .codex, let effort = patch.effort {
            guard await isKnownCodexEffort(effort) else { return .invalidEffort }
        }

        // C4-a: try the live switch before persisting (W11-g setModel displayName
        // re-resolution requires the RPC). `.custom` also rides DabSessionBridge.
        if session.backend == .claude || session.backend == .custom {
            if let model = patch.model {
                guard await setModelClaude(channelId, model) else { return .applyFailed }
            }
            if let effort = patch.effort {
                guard await setEffortClaude(channelId, effort) else { return .applyFailed }
            }
        }

        // Field patches must not wipe the resume id unless explicitly requested.
        session = applyPatch(to: session, patch, now: now())
        do {
            try await store.upsert(channelId: channelId, session)
        } catch {
            return .persistFailed
        }
        await registry.bind(channelId: channelId, sessionConfig(from: session))

        let action: String
        if patch.model != nil { action = "model" }
        else if patch.effort != nil { action = "effort" }
        else if patch.permMode != nil { action = "mode.perm" }
        else { action = "binding" }

        await audit.record(AuditEntry(
            actorId: actorId,
            roleTier: roleTier,
            guildId: guildId,
            channelId: channelId,
            action: action,
            mode: session.backend.rawValue,
            permMode: session.permMode,
            status: "ok"
        ))
        return .ok
    }

    /// Replace a channel binding after a wizard has durably saved its new configuration. The
    /// save happens first so a write failure leaves the current live bridge and registry intact;
    /// successful replacement always drops every old bridge before publishing the new registry
    /// binding, preventing old handles from being reused by the new configuration.
    @discardableResult
    public func replaceBinding(channelId: String, with session: PersistedSession) async -> Bool {
        var replacement = session
        replacement.lifecycleGeneration = UUID().uuidString
        replacement.contextGenerationStartedAt = now()
        do {
            try await store.upsert(channelId: channelId, replacement)
        } catch {
            return false
        }
        await stopAllBridges(channelId: channelId)
        await registry.bind(channelId: channelId, sessionConfig(from: replacement))
        return true
    }

    /// `/agent resume`: re-register registry from a non-archived store row (G-P1-05).
    /// Returns the store row (cwd / backendSessionId for intro + soft ensure), or nil when none.
    public func resumeBinding(channelId: String) async -> PersistedSession? {
        guard let session = await store.binding(channelId: channelId), !session.archived else {
            return nil
        }
        await registry.bind(channelId: channelId, sessionConfig(from: session))
        return session
    }

    /// Best-effort: open or resume the backend session **without** a user turn (G-P1-05).
    /// No-ops when already live or no non-archived store row. Failures stay false (first message retries).
    @discardableResult
    public func softEnsureLive(channelId: String) async -> Bool {
        guard let session = await store.binding(channelId: channelId), !session.archived else {
            return false
        }
        let config = sessionConfig(from: session)
        switch session.backend {
        case .claude, .custom:
            return await DabSessionBridge.shared.softEnsure(
                channelId: channelId,
                guildId: session.guildId,
                ownerId: session.ownerId,
                config: config
            )
        case .codex:
            return await CodexSessionBridge.shared.softEnsure(
                channelId: channelId,
                guildId: session.guildId,
                ownerId: session.ownerId,
                config: config
            )
        case .grok:
            return await GrokSessionBridge.shared.softEnsure(
                channelId: channelId,
                guildId: session.guildId,
                ownerId: session.ownerId,
                config: config
            )
        }
    }

    /// C10: boot recovery — TS `sessionOrchestrator.resumeAll()` + `app.ts`'s boot attach loop merged
    /// into one pass (Swift has no separate Discord "wiring/attach" object to re-subscribe, so
    /// checking channel existence and reconnecting the backend happen together per channel). For
    /// every non-archived store binding, concurrently: (1) ask `channelGone` whether Discord confirms
    /// the channel is permanently deleted (10003) — if so, hard-clean the binding via `stopChannel`
    /// (same path as a live `channelDelete` event) and skip resume entirely (avoids TS's own
    /// documented "resume then immediately kill the orphan" waste); otherwise (2) attempt
    /// `resumeSession` so a live session survives a restart without waiting for the channel's next
    /// message. Neither closure throws, so one channel's failure can never cancel or affect another
    /// (TS `Promise.allSettled` semantics via Swift's TaskGroup). `channelGone` defaults to "never
    /// gone" (TS `wiring.ts`'s documented safe default for a caller without Discord access — e.g. a
    /// test — so it can never trigger cleanup). `resumeSession` defaults to `softEnsureLive` itself;
    /// tests override it to avoid touching the live `.shared` bridge singletons.
    @discardableResult
    public func resumeAll(
        channelGone: @escaping @Sendable (String) async -> Bool = { _ in false },
        resumeSession: (@Sendable (String) async -> Bool)? = nil
    ) async -> (total: Int, resumed: Int, cleaned: Int) {
        let bindings = await store.active()
        let resume = resumeSession ?? { channelId in await self.softEnsureLive(channelId: channelId) }

        let outcomes = await withTaskGroup(of: (gone: Bool, resumed: Bool).self) { group in
            for (channelId, ps) in bindings {
                group.addTask {
                    if await channelGone(channelId) {
                        _ = await self.stopChannel(
                            channelId: channelId, actorId: "system", guildId: ps.guildId, roleTier: "execute"
                        )
                        return (gone: true, resumed: false)
                    }
                    return (gone: false, resumed: await resume(channelId))
                }
            }
            var collected: [(gone: Bool, resumed: Bool)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        return (
            total: bindings.count,
            resumed: outcomes.filter(\.resumed).count,
            cleaned: outcomes.filter(\.gone).count
        )
    }

    /// Active bindings for `/agent stats` (registry ∪ non-archived store; registry wins on model/effort).
    /// G-P2-04: attaches per-channel `running` / `queueDepth` from bridge gate chains (TS listActive).
    public func listActiveBindings() async -> [StatsBindingLine] {
        var out: [String: (Backend, String?, String?)] = [:]
        for (id, ps) in await store.active() {
            out[id] = (ps.backend, ps.model, ps.effort)
        }
        for (id, cfg) in await registry.list() {
            out[id] = (cfg.backend, cfg.model, cfg.effort)
        }
        var lines: [StatsBindingLine] = []
        for id in out.keys.sorted() {
            let v = out[id]!
            let status = await turnStatus(channelId: id)
            lines.append(StatsBindingLine(
                channelId: id,
                backend: v.0,
                model: v.1,
                effort: v.2,
                queueDepth: status.queueDepth,
                running: status.running
            ))
        }
        return lines
    }

    /// Soft turn status across all three bridges (any in-flight/waiting counts as running).
    private func turnStatus(channelId: String) async -> (running: Bool, queueDepth: Int) {
        let claudeDepth = await DabSessionBridge.shared.turnQueueDepth(channelId: channelId)
        let codexDepth = await CodexSessionBridge.shared.turnQueueDepth(channelId: channelId)
        let grokDepth = await GrokSessionBridge.shared.turnQueueDepth(channelId: channelId)
        let claudeRun = await DabSessionBridge.shared.isTurnRunning(channelId: channelId)
        let codexRun = await CodexSessionBridge.shared.isTurnRunning(channelId: channelId)
        let grokRun = await GrokSessionBridge.shared.isTurnRunning(channelId: channelId)
        return (
            running: claudeRun || codexRun || grokRun,
            queueDepth: max(claudeDepth, codexDepth, grokDepth)
        )
    }

    // MARK: - private

    private func stopAllBridges(channelId: String) async {
        await stopClaude(channelId)
        await stopCodex(channelId)
        await stopGrok(channelId)
    }

    private func resolveBackend(channelId: String) async -> Backend? {
        if let b = await registry.binding(channelId: channelId)?.backend { return b }
        return await store.binding(channelId: channelId)?.backend
    }

    /// Prefer store row; fall back to registry-only stub so clear/mode/patch still work after
    /// `/agent start` before the first turn writes store (or if store load failed).
    private func resolveSession(
        channelId: String,
        guildId: String,
        defaultCwd: String
    ) async -> PersistedSession? {
        if let s = await store.binding(channelId: channelId) { return s }
        guard let cfg = await registry.binding(channelId: channelId) else { return nil }
        return PersistedSession(
            backend: cfg.backend,
            backendSessionId: nil,
            cwd: defaultCwd,
            guildId: guildId,
            ownerId: nil,
            model: cfg.model,
            effort: cfg.effort,
            permMode: cfg.permMode,
            updatedAt: now()
        )
    }
}

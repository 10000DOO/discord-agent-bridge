import Foundation

private let log = Logger(name: "claude")

/// Shared Claude sidecar + per-channel session map for the minimal `!claude` path (W9b).
public actor DabSessionBridge {
    public static let shared = DabSessionBridge()

    /// Client factory (test seam). Default = real sidecar spawn. Injected via `@testable` in tests.
    private let makeClient: @Sendable () throws -> ClaudeSidecarClient
    /// Test seam: override the turn timeout (default nil → DAB_TURN_TIMEOUT_SEC env, floor 5s).
    private let turnTimeoutOverrideNs: UInt64?
    /// Permission gate (default the process-wide shared one; tests inject a fresh gate for isolation).
    private let gate: PermissionGate
    /// Session persistence (default shared; tests inject a temp-file store for isolation).
    private let store: SessionStore
    /// Global config (autoAllowClaudeTools). Tests inject a temp-dir store.
    private let configStore: ConfigStore
    /// Custom-backend shell env (default = real dotfile scan; tests inject fixed result).
    private let resolveCustomEnvFn: @Sendable () -> CustomEnvResult

    init(
        makeClient: @escaping @Sendable () throws -> ClaudeSidecarClient = {
            let spawn = resolveClaudeSidecarSpawn()
            log.info("spawning claude sidecar: \(spawn.command) \(spawn.args.joined(separator: " "))")
            return try ClaudeSidecarClient(spawn: spawn, requestTimeoutMs: 120_000)
        },
        turnTimeoutOverrideNs: UInt64? = nil,
        gate: PermissionGate = .shared,
        store: SessionStore = .shared,
        configStore: ConfigStore = .shared,
        resolveCustomEnvFn: @escaping @Sendable () -> CustomEnvResult = { resolveCustomEnv() }
    ) {
        self.makeClient = makeClient
        self.turnTimeoutOverrideNs = turnTimeoutOverrideNs
        self.gate = gate
        self.store = store
        self.configStore = configStore
        self.resolveCustomEnvFn = resolveCustomEnvFn
    }

    /// One-shot notice to prepend to the next reply when a stored session failed to resume (F5).
    private var fallbackNotice: [String: String] = [:]

    private var client: ClaudeSidecarClient?
    /// channelId (snowflake string) → sidecar session handle
    private var sessions: [String: String] = [:]
    /// handle → (channelId, approverId) for routing permission prompts (approver = session's first-turn owner).
    private var sessionMeta: [String: (channelId: String, approverId: String?)] = [:]
    /// handle → in-flight turn accumulator
    private var turns: [String: TurnBox] = [:]
    /// channelId → epoch bumped on `stop` so sessionHandle that races mid-await drops the orphan.
    private var stopEpoch: [String: UInt64] = [:]
    /// Serialize turns per channel (avoid concurrent send on same session).
    private var channelGates: [String: Task<Void, Error>] = [:]
    /// Per-channel count of `runTurn` callers (in-flight + waiting on the gate chain).
    /// G-P2-04: `running` = depth > 0; queueDepth = max(0, depth − 1).
    private var turnDepth: [String: Int] = [:]
    /// Per-handle FIFO chain so text → result events cannot reorder across the
    /// sync-handler → actor hop (`Task { await onEvent }`). Under parallel load a bare Task
    /// hop can finish the turn before appendText, yielding "(empty result)".
    private let eventChains = LockedBox<[String: Task<Void, Never>]>([:])

    private struct TurnBox {
        var text = ""
        var usage: TurnUsage?
        var contextUsage: ContextUsageInfo?
        var rateLimit: RateLimitInfo?
        /// Turn-local tools/subagent HUD aggregates (W11-g slice4). Reset after every push (WO-5).
        var stats = TurnToolStatsAggregator()
        /// WO-5 (docs/claude-turn-timeout-delay.md): true once the FIRST terminal-ish event
        /// (`.result` / `.turnComplete` / `.error`) has resumed `continuation`. After that there is
        /// no more judgment about "is this really the end" — further events on this handle
        /// (subagent-triggered `.result`, etc.) just keep pushing through `onAnswer`, exactly like
        /// TS 1.x's `RendererDispatcher` (gating-free, resend on every `result`). Only this one-shot
        /// flag still exists, to (a) resume the `Void` continuation exactly once and (b) let the
        /// caller know when to fire the one-shot completion decoration (emoji/stream/stop
        /// button/IdleWatchdog) — TS `armCompletionIndicator` parity (first result/error, one-shot).
        var terminalStarted = false
        /// Delivered once per `.result` (or the rare `.turnComplete`-without-`.result` safety net),
        /// gating-free — the caller (DabMain/RedmineKickoffPrompt) does the actual Discord posting.
        var onAnswer: (@Sendable (TurnResult) -> Void)?
        var continuation: CheckedContinuation<Void, Error>?
        var timeoutTask: Task<Void, Never>?
    }

    /// Build TurnResult from the live box (tools/agents snapshotted at push time).
    private func makeTurnResult(box: TurnBox, text: String) -> TurnResult {
        TurnResult(
            text: text,
            usage: box.usage,
            contextUsage: box.contextUsage,
            rateLimit: box.rateLimit,
            tools: box.stats.toolsSnapshot(),
            agents: box.stats.agentsSnapshot()
        )
    }

    private var cwd: String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["DAB_CWD"], !v.isEmpty { return v }
        return NSHomeDirectory()
    }

    private var permMode: String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["DAB_PERM_MODE"], !v.isEmpty { return v }
        // Smoke-friendly default: no permission UI. Dangerous on real machines — document it.
        return "bypassPermissions"
    }

    private var turnTimeoutNs: UInt64 {
        if let turnTimeoutOverrideNs { return turnTimeoutOverrideNs }
        let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 10_800
        return UInt64(max(5, sec)) * 1_000_000_000
    }

    /// (Re)arm this turn's hang-timeout watchdog: fires `finishTurn(timeoutFallback:)` after
    /// `turnTimeoutNs` unless cancelled first. Called once when the turn starts (`executeTurn`)
    /// and again on every received event (`onEvent`, any kind) so a live turn's fixed window keeps
    /// getting pushed out by activity — only a turn with zero events for the full window ever
    /// hits the fallback (the "completely hung session" safety net stays intact). WO-5: this only
    /// matters BEFORE the first terminal-ish event — once answered, the timer is left cancelled
    /// (nothing left to protect; see `onEvent`/`deliverTerminal`).
    private func armTimeoutTask(handle: String) -> Task<Void, Never> {
        let timeoutNs = turnTimeoutNs
        return Task {
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard !Task.isCancelled else { return }
            self.finishTurn(handle: handle, error: nil, timeoutFallback: true)
        }
    }

    func ensureClient() async throws -> ClaudeSidecarClient {
        // Reuse a live client; a closed one (crashed/EOF) is dropped and respawned
        // (mirrors CodexSessionBridge/GrokSessionBridge.ensureChannel). The dead client's session
        // handles are invalid, so clear them — otherwise the next turn reuses a stale handle on the
        // fresh client and never registers a session handler (turn hangs).
        if let client {
            if !client.isClosed { return client }
            await client.close()
            self.client = nil
            self.sessions.removeAll()
        }
        let c = try makeClient()
        self.client = c
        c.addCloseHandler { [weak self, weak c] error in
            guard let c else { return }
            Task { await self?.handleClientClosed(c, error: error) }
        }
        do {
            try await c.connect()
        } catch {
            // connect failed: close the spawned child so it does not leak as an orphan.
            await c.close()
            if self.client === c { self.client = nil }
            throw error
        }
        log.info("sidecar ready (cwd=\(cwd) permMode=\(permMode))")
        return c
    }

    /// A sidecar EOF invalidates every handle on its single shared transport. Acknowledged turns
    /// otherwise wait for their terminal event until the turn timer fires, so fail them now and
    /// force the next turn through `ensureClient()` to create a fresh client/session.
    private func handleClientClosed(_ closedClient: ClaudeSidecarClient, error: SidecarRpcError) async {
        // `onEvent` is queued from the synchronous client callback. EOF can schedule this handler
        // before the queued terminal result reaches this actor, so drain the tails that existed at
        // close notification before deciding which turns still need a transport failure.
        let handles = Array(sessionMeta.keys)
        let tails = eventChains.withLock { chains in handles.compactMap { chains[$0] } }
        for tail in tails { await tail.value }
        guard client === closedClient else { return }
        for (handle, var box) in turns where !box.terminalStarted {
            // EOF proves no further event can ever arrive. A turn that never got a first answer at
            // all is a hard failure; one that had already accumulated some text (e.g. `.text`
            // deltas with no `.result` yet) retains it instead of failing.
            if box.text.isEmpty {
                finishWithError(handle: handle, error: error)
            } else {
                deliverTerminal(handle: handle, box: &box)
            }
        }
        sessions.removeAll()
        sessionMeta.removeAll()
        client = nil
        log.warn("sidecar transport closed; invalidated live Claude sessions")
    }

    /// Live Claude model/permission/effort catalog via the sidecar (W11-h). R4: any sidecar
    /// failure (not spawned / RPC error / transport) degrades to the alias/degraded fallback
    /// rather than throwing — the wizard/slash caller always gets a usable snapshot.
    public func claudeCatalog() async -> ClaudeCatalogSnapshot {
        do {
            let c = try await ensureClient()
            return ClaudeCatalogSnapshot(from: try await c.claudeCatalog())
        } catch {
            return .fallback
        }
    }

    /// Resumable Claude sessions for `cwd` via sidecar `sessions.list` (W11-b2 resume UI).
    /// Failures → empty (resume wizard shows "재개할 세션이 없습니다").
    public func listResumableSessions(cwd: String, limit: Int = 25) async -> [ResumableSession] {
        do {
            let c = try await ensureClient()
            let result = try await c.sessionsList(cwd: cwd, limit: limit)
            return result.sessions
        } catch {
            log.warn("sessions.list failed (\(error))")
            return []
        }
    }

    /// Send user text for a Discord channel. `onAnswer` fires once per `.result` (WO-5 push
    /// model, docs/claude-turn-timeout-delay.md) — no gating, no "is this the last one" judgment;
    /// a background-subagent-triggered follow-up `.result` on the same handle just fires it again.
    /// This function itself returns once the FIRST terminal-ish event (`.result` / rare
    /// `.turnComplete`-without-`.result` / `.error`) has already been pushed — matching the old
    /// synchronous timing so the caller's one-shot "turn accepted" bookkeeping is unaffected.
    /// Turns on the same channel are serialized. `files` are confined workspace paths (G-P0-01)
    /// forwarded to sidecar `session.send`.
    public func runTurn(
        channelId: String,
        guildId: String,
        ownerId: String?,
        text: String,
        config: SessionConfig? = nil,
        files: [TurnFile] = [],
        onAnswer: @escaping @Sendable (TurnResult) -> Void
    ) async throws {
        if !(await ProviderRuntimeMaintenanceGate.shared.reserveTurnIfAvailable()) {
            await ProviderRuntimeMaintenanceGate.shared.reserveTurn()
        }
        defer { Task { await ProviderRuntimeMaintenanceGate.shared.releaseTurn() } }
        // Read + install the gate with NO await between them, so a reentering job cannot install a
        // rival task against the same session. The previous turn is awaited INSIDE the task — that
        // is where serialization happens.
        let prev = channelGates[channelId]
        turnDepth[channelId, default: 0] += 1
        let task = Task {
            if let prev { _ = try? await prev.value }
            try await self.executeTurn(
                channelId: channelId,
                guildId: guildId,
                ownerId: ownerId,
                text: text,
                config: config,
                files: files,
                onAnswer: onAnswer
            )
        }
        channelGates[channelId] = task
        defer {
            turnDepth[channelId, default: 1] -= 1
            if turnDepth[channelId] == 0 { turnDepth[channelId] = nil }
            if channelGates[channelId] == task { channelGates[channelId] = nil }
        }
        try await task.value
    }

    /// G-P2-04: any turn in-flight or waiting on this channel's gate chain.
    public func isTurnRunning(channelId: String) -> Bool {
        (turnDepth[channelId] ?? 0) > 0
    }

    public func isAnyTurnRunning() -> Bool {
        turnDepth.values.contains { $0 > 0 }
    }

    /// G-P2-04: turns waiting behind the running one (TS `queueDepth`).
    public func turnQueueDepth(channelId: String) -> Int {
        max(0, (turnDepth[channelId] ?? 0) - 1)
    }

    private func executeTurn(
        channelId: String,
        guildId: String,
        ownerId: String?,
        text: String,
        config: SessionConfig?,
        files: [TurnFile],
        onAnswer: @escaping @Sendable (TurnResult) -> Void
    ) async throws {
        let client = try await ensureClient()
        let handle = try await sessionHandle(
            client: client,
            channelId: channelId,
            guildId: guildId,
            ownerId: ownerId,
            config: config
        )

        // Files are realpath-confined at download (AttachmentDownload). Forward to sidecar.
        let fileParams: [[String: String]]? = files.isEmpty
            ? nil
            : files.map { f in
                var o = ["path": f.path]
                if let mime = f.mime { o["mime"] = mime }
                return o
            }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            turns[handle] = TurnBox(
                text: "",
                usage: nil,
                onAnswer: onAnswer,
                continuation: cont,
                timeoutTask: armTimeoutTask(handle: handle)
            )

            Task {
                do {
                    try await client.sessionSend(session: handle, text: text, files: fileParams)
                } catch {
                    self.finishTurn(handle: handle, error: error)
                }
            }
        }
    }

    private func sessionHandle(
        client: ClaudeSidecarClient,
        channelId: String,
        guildId: String,
        ownerId: String?,
        config: SessionConfig?
    ) async throws -> String {
        if let existing = sessions[channelId] {
            return existing
        }
        let epoch = stopEpoch[channelId] ?? 0
        // W11-f2: resume params reuse the STORED model/effort/permMode (T6) so a reconnect keeps the
        // original session's settings; live config/env fill in when nothing was persisted.
        let persisted = await store.binding(channelId: channelId)
        // custom runs on the Claude sidecar path with shell-env overlay (TS CustomMode).
        let backend: Backend = {
            if let b = config?.backend { return b }
            if let b = persisted?.backend, b == .custom || b == .claude { return b }
            return .claude
        }()
        var model = persisted?.model ?? config?.model
        let effort = persisted?.effort ?? config?.effort
        var perm = persisted?.permMode ?? config?.permMode ?? permMode
        let cwdValue = persisted?.cwd ?? cwd

        // W16-f: prepareSession for custom — merge process env + allow-listed dotfile keys;
        // prefer ANTHROPIC_MODEL over wizard/ctx model (TS prepareCustomSession).
        var sessionEnv: [String: String?]?
        if backend == .custom {
            let resolved = resolveCustomEnvFn()
            if resolved.hasDangerousFlag, perm != "bypassPermissions" {
                log.warn(
                    "custom backend alias contains --dangerously-skip-permissions but permMode is not bypassPermissions source=\(resolved.source ?? "?")"
                )
            }
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in resolved.env { merged[k] = v }
            sessionEnv = merged.mapValues { Optional.some($0) }
            if let m = resolved.env["ANTHROPIC_MODEL"], !m.isEmpty {
                model = m
            }
            log.info(
                "custom backend env resolved source=\(resolved.source ?? "nil") keys=\(resolved.env.keys.sorted())"
            )
        }

        // Thread the layered permission profile's allowedTools (+ global autoAllowClaudeTools
        // fallback) and permissionTimeoutSec into the sidecar (TS PermissionResolver.resolve() +
        // sessionOrchestrator.buildContext: modeConfig.allowedTools = modeConfig.autoAllowClaudeTools
        // = perm.allowedTools). Profiles are looked up from the top-level config only (never
        // server-layered, matching TS); permissionTimeoutSec IS server-layered via ConfigResolver.
        // M2: a profile name that no longer exists in config.profiles (e.g. deleted after a channel
        // bound to it) now blocks session start with an error, matching TS
        // permissionResolver.ts:66-70 (`throw new Error("Unknown permission profile '<name>'.")`) —
        // a stale profile reference is a config mistake the operator needs to see, not something to
        // paper over with the global auto-allow list.
        // H8: when the profile IS found, its permissionMode supersedes any persisted/env value
        // computed above — permissionMode is re-resolved from live config on every session start,
        // exactly like allowedTools already is below (both come from the same profile record, TS
        // permissionResolver.ts:71-72).
        // Same fail-secure treatment when config.json itself is missing/unreadable: empty
        // allowedTools + 0 timeout (matches ConfigStore.autoAllowClaudeTools()'s own "or empty
        // when config is missing/unreadable" contract) instead of throwing the turn.
        var effectiveAllowedTools: [String] = []
        var effectivePermissionTimeoutSec = 0
        if let globalConfig = try? await configStore.load() {
            let resolvedConfig = try? await ConfigResolver(
                configStore: configStore,
                bindingSource: SessionStoreBindingSource(store: store)
            ).resolve(guildId: guildId, channelId: channelId)
            if let profileName = resolvedConfig?.permissionProfile {
                guard let profile = globalConfig.profiles[profileName] else {
                    throw SidecarRpcError(
                        code: "unknown_profile",
                        message: "Unknown permission profile '\(profileName)'."
                    )
                }
                perm = profile.permissionMode
            }
            effectiveAllowedTools = resolvedConfig?.permissionProfile
                .flatMap { globalConfig.profiles[$0]?.allowedTools }
                ?? globalConfig.autoAllowClaudeTools
            effectivePermissionTimeoutSec = resolvedConfig?.limits.permissionTimeoutSec ?? 0
        }
        let sessionCfg = SessionStartParams.SessionConfig(
            allowedTools: effectiveAllowedTools.isEmpty ? nil : effectiveAllowedTools,
            autoAllowClaudeTools: effectiveAllowedTools.isEmpty ? nil : effectiveAllowedTools,
            permissionTimeoutSec: effectivePermissionTimeoutSec
        )
        let params = SessionStartParams(
            cwd: cwdValue, guildId: guildId, channelId: channelId, ownerId: ownerId,
            model: model, effort: effort, permMode: perm, config: sessionCfg, env: sessionEnv
        )

        // Resume the stored backend session if we have one; on failure fall back to a fresh start (F5).
        let started: SessionStartResult
        var startedFresh = persisted?.backendSessionId == nil
        if let resumeId = persisted?.backendSessionId {
            do {
                started = try await client.sessionResume(params, backendSessionId: resumeId)
                log.info("session.resume channel=\(channelId) backend=\(resumeId)")
            } catch {
                fallbackNotice[channelId] = sessionFallbackNotice()
                started = try await client.sessionStart(params)
                startedFresh = true
                log.warn("session.resume failed (\(error)) → start channel=\(channelId)")
            }
        } else {
            started = try await client.sessionStart(params)
        }

        let handle = started.session
        // stop raced mid-start → drop orphan session on the shared sidecar.
        if (stopEpoch[channelId] ?? 0) != epoch {
            try? await client.sessionStop(session: handle)
            throw SidecarRpcError(code: "interrupted", message: "session stopped")
        }
        sessions[channelId] = handle
        sessionMeta[handle] = (channelId: channelId, approverId: ownerId)
        let store = self.store
        let persistBackend = backend
        let persistModel = model
        let persistGeneration = persisted?.lifecycleGeneration
        let persistContextGenerationStartedAt = startedFresh ? iso8601Now() : nil
        // H8: `perm` may have been reassigned from the live profile lookup above — snapshot it
        // (same as `persistModel`) so the escaping onBackendId closure captures an immutable value.
        let persistPerm = perm
        // host.file.share / host.file.attach reverse RPC → Host sinks (Discord wired in dab).
        let shareChannelId = channelId
        // Extend the chain *synchronously* in the event callback so arrival order is kept
        // even when work hops onto this actor.
        client.registerSessionHandlers(
            handle: handle,
            handlers: SidecarSessionHandlers(
                onEvent: { [weak self] ev in
                    guard let self else { return }
                    self.eventChains.withLock { chains in
                        let prev = chains[handle]
                        let next = Task {
                            _ = await prev?.value
                            await self.onEvent(handle: handle, event: ev)
                        }
                        chains[handle] = next
                    }
                },
                // F7 / T3: Claude's backend id may arrive only after init — persist it when it lands.
                onBackendId: { backendId in
                    Task {
                        await persistSession(
                            store: store, backend: persistBackend, channelId: channelId,
                            guildId: guildId, ownerId: ownerId, cwd: cwdValue,
                            model: persistModel, effort: effort, permMode: persistPerm,
                            backendSessionId: backendId, lifecycleGeneration: persistGeneration,
                            contextGenerationStartedAt: persistContextGenerationStartedAt
                        )
                    }
                },
                onFileAttach: { path, name in
                    try await FileAttachHost.shared.attach(channelId: shareChannelId, path: path, name: name)
                },
                onFileShare: { path in
                    try await DocumentShareHost.shared.share(channelId: shareChannelId, path: path)
                }
            )
        )
        // F7: if start/resume already gave a backend id, persist it now. If null (T3), the onBackendId
        // notify above records it later — we do NOT persist a null id here.
        if let bid = started.backendSessionId {
            await persistSession(
                store: store, backend: persistBackend, channelId: channelId,
                guildId: guildId, ownerId: ownerId, cwd: cwdValue,
                model: persistModel, effort: effort, permMode: persistPerm,
                backendSessionId: bid, lifecycleGeneration: persistGeneration,
                contextGenerationStartedAt: persistContextGenerationStartedAt
            )
        }
        if (stopEpoch[channelId] ?? 0) != epoch {
            sessions[channelId] = nil
            sessionMeta[handle] = nil
            client.unregisterSessionHandlers(handle: handle)
            try? await client.sessionStop(session: handle)
            throw SidecarRpcError(code: "interrupted", message: "session stopped")
        }
        log.info("session.start channel=\(channelId) handle=\(handle)")
        return handle
    }

    private func onEvent(handle: String, event: AgentEvent) {
        // WO-5 (docs/claude-turn-timeout-delay.md): the old `!box.done` gate that silently dropped
        // every event after the first `.result` is gone — a handle keeps accepting events (and
        // keeps pushing them out via `onAnswer`) for as long as its box exists, exactly like TS
        // 1.x's gating-free `RendererDispatcher`. The box is only ever replaced wholesale by the
        // NEXT user message's `executeTurn` call, or dropped by `stop()`.
        guard var box = turns[handle] else { return }
        // WO-2: any activity (any event kind) pushes the hang-timeout window back out — but only
        // while no answer has gone out yet; once `terminalStarted`, there is nothing left to guard
        // against hanging (the caller already got its first answer), so the timer stays cancelled.
        if !box.terminalStarted {
            box.timeoutTask?.cancel()
            box.timeoutTask = armTimeoutTask(handle: handle)
            turns[handle] = box
        }
        // H2: confirm whether/when .result and .turn_complete actually arrive per turn (see
        // docs/claude-turn-timeout-delay.md WO-3). warn level — info is lost to stdout buffering
        // under launchd (docs/log-buffering-lost-info-logs.md).
        log.warn("[DAB-DIAG-EVENT-SEQ] handle=\(handle) kind=\(event.kind)")
        switch event {
        case .text(let t, _):
            box.text += t
            turns[handle] = box
            // W11-g residual: live stream status embed (rate-limited in StreamStatusHost).
            if let channelId = sessionMeta[handle]?.channelId {
                Task { await StreamStatusHost.shared.noteText(channelId: channelId, delta: t) }
            }
        case .result(let t, let costUsd, let tokensIn, let tokensOut, let durationMs):
            if let t, !t.isEmpty {
                if box.text.isEmpty {
                    box.text = t
                } else if !box.text.contains(t) {
                    box.text += t
                }
            }
            // This result's own cost/tokens/duration — TS renders then clears every time, never a
            // running total. `nil` when this event carries no metrics, overwriting any stale value.
            box.usage = turnUsage(fromResult: costUsd, tokensIn: tokensIn, tokensOut: tokensOut, durationMs: durationMs)
            // WO-5: push immediately, no "is this the last one" judgment — a background-subagent
            // follow-up `.result` on the same handle fires this again later, same as any other one.
            deliverTerminal(handle: handle, box: &box)
        case .turnComplete:
            // The Claude SDK's session_state_changed:idle. Production evidence (H2) shows this
            // basically never arrives. Kept only as WO-1's original safety net: if the FIRST
            // terminal-ish event hasn't happened yet, finish on whatever text accumulated instead
            // of stalling until the turn-timeout fallback. Once a `.result` has already delivered
            // the first answer, this is a no-op (no more "last event" judgment to make).
            guard !box.terminalStarted else { return }
            deliverTerminal(handle: handle, box: &box)
        case .contextUsage:
            // Turn-local snapshot — shown at the next push then cleared (TS renderers/index.ts
            // usage(ev): render then clear every time, never accumulated).
            if let info = ContextUsageInfo.from(event: event) {
                box.contextUsage = info
                turns[handle] = box
            }
        case .rateLimit(let resetAt, let rateLimitType, let utilization):
            // Turn-local snapshot — shown at the next push then cleared, same as contextUsage.
            let info = RateLimitInfo(
                resetAt: resetAt,
                rateLimitType: rateLimitType,
                utilization: utilization
            )
            box.rateLimit = info
            turns[handle] = box
        case .error(let message, _):
            // No-op once a prior `.result` already delivered an answer — `finishWithError`'s own
            // `!terminalStarted` guard covers this (nothing left to fail).
            finishWithError(handle: handle, error: SidecarRpcError(code: "sdk_error", message: message))
        case .permissionRequest(let id, let toolName, let input):
            // Ask the owner via Discord buttons; waits forever if unanswered (TS parity — no
            // timeout). Answers the sidecar with the decision so the tool proceeds/aborts. Does not
            // touch the turn accumulator.
            // W16-e: tools in global autoAllowClaudeTools auto-allow without a button (mid-session
            // always-allow takes effect immediately on the host even if the sidecar list is stale).
            let meta = sessionMeta[handle]
            let client = self.client
            let configStore = self.configStore
            let gate = self.gate
            Task {
                if await isAutoAllowedClaudeTool(toolName, store: configStore) {
                    try? await client?.sessionPermission(session: handle, requestId: id, behavior: "allow")
                    return
                }
                let prompt = PermissionPrompt(
                    reqKey: UUID().uuidString,
                    channelId: meta?.channelId ?? "",
                    toolName: toolName,
                    detail: permissionDetail(input),
                    approverId: meta?.approverId
                )
                let decision = await gate.await(prompt: prompt)
                try? await client?.sessionPermission(
                    session: handle,
                    requestId: id,
                    behavior: decision.backendBehavior
                )
            }
        case .toolUse, .toolResult:
            // W11-g slice4: turn-local tool counts for usage embed HUD.
            box.stats.note(event)
            turns[handle] = box
            // W16-g: tool activity → Discord work threads + diffs (fire-and-forget).
            // W11-g residual: stream status tool-count bump on tool_use only.
            if let channelId = sessionMeta[handle]?.channelId {
                let ev = event
                Task { await ToolActivityHost.shared.handle(channelId: channelId, event: ev) }
                if case .toolUse = event {
                    Task { await StreamStatusHost.shared.noteToolUse(channelId: channelId) }
                }
            }
        case .subagentResult:
            // W11-g slice4: pair with Task/Agent tool_use input for the agents field.
            box.stats.note(event)
            turns[handle] = box
        case .progress(let label, let detail):
            // W11-g residual: progress line on the live stream embed.
            if let channelId = sessionMeta[handle]?.channelId {
                Task {
                    await StreamStatusHost.shared.noteProgress(
                        channelId: channelId, label: label, detail: detail
                    )
                }
            }
        case .thinking(let t, _):
            // G-P0-03: thinking deltas → purple stream embed only; never reply buffer.
            if let channelId = sessionMeta[handle]?.channelId, !t.isEmpty {
                Task { await StreamStatusHost.shared.noteThinking(channelId: channelId, delta: t) }
            }
        }
    }

    private func finishTurn(handle: String, error: Error?, timeoutFallback: Bool = false) {
        guard var box = turns[handle], !box.terminalStarted else { return }
        if let error {
            finishWithError(handle: handle, error: error)
            return
        }
        if timeoutFallback {
            if box.text.isEmpty {
                // 응답이 전혀 없는 완전 먹통 타임아웃 — 이 handle의 사이드카 세션은 죽은 것으로 간주하고
                // sessions[channelId] 매핑을 지운다. 안 지우면 다음 turn도 같은 죽은 handle을 계속
                // 재사용해서 영원히 같은 타임아웃을 반복한다 (redmine 착수 재발 버그의 실제 원인).
                let channelId = sessionMeta[handle]?.channelId
                let stderrTail = client?.stderrBuffer.suffix(2000) ?? ""
                log.warn("[DAB-DIAG-SIDECAR-STDERR] handle=\(handle) channel=\(channelId ?? "?") tail=\(stderrTail)")
                if let channelId, sessions[channelId] == handle {
                    sessions[channelId] = nil
                }
                sessionMeta[handle] = nil
                client?.unregisterSessionHandlers(handle: handle)
                let deadClient = client
                Task { try? await deadClient?.sessionStop(session: handle) }
                finishWithError(
                    handle: handle,
                    error: SidecarRpcError(
                        code: "internal",
                        message: "turn timeout (no terminal result)",
                        retryable: true
                    )
                )
            } else {
                box.text += "\n…(timeout)"
                deliverTerminal(handle: handle, box: &box)
            }
        }
    }

    /// Fail the turn outright (no answer ever went out). No-op once a prior `.result` already
    /// delivered one (`!box.terminalStarted` guard) — there is nothing left to fail.
    private func finishWithError(handle: String, error: Error) {
        guard var box = turns[handle], !box.terminalStarted else { return }
        box.terminalStarted = true
        box.timeoutTask?.cancel()
        box.timeoutTask = nil
        let cont = box.continuation
        box.continuation = nil
        turns[handle] = box
        // W16-g: turn boundary for tool threads (in-flight posts keep their captured thread).
        if let channelId = sessionMeta[handle]?.channelId {
            Task { await ToolActivityHost.shared.resetTurn(channelId: channelId) }
        }
        cont?.resume(throwing: error)
    }

    /// Deliver one push: this event's accumulated text (+ this-event usage, turn-local
    /// contextUsage/rateLimit/tools/agents snapshots) via `onAnswer`, gating-free (WO-5) — then
    /// reset the per-push accumulators (TS parity: render then clear, never summed). On the FIRST
    /// call only, also resumes `runTurn`'s continuation so the caller's one-shot completion
    /// decoration (emoji/stream/stop button/IdleWatchdog) fires right after — TS
    /// `armCompletionIndicator` parity (first result/error, one-shot, unrelated to answer delivery).
    private func deliverTerminal(handle: String, box: inout TurnBox) {
        var text = box.text.isEmpty ? "(empty result)" : box.text
        let isFirst = !box.terminalStarted
        // F5: prepend the resume-failure notice once, on the very first answer only.
        if isFirst, let channelId = sessionMeta[handle]?.channelId,
           let notice = fallbackNotice.removeValue(forKey: channelId) {
            text = notice + "\n\n" + text
        }
        let pushResult = makeTurnResult(box: box, text: text)
        box.text = ""
        box.contextUsage = nil
        box.rateLimit = nil
        box.stats.reset()
        var cont: CheckedContinuation<Void, Error>?
        if isFirst {
            box.terminalStarted = true
            box.timeoutTask?.cancel()
            box.timeoutTask = nil
            cont = box.continuation
            box.continuation = nil
        }
        turns[handle] = box
        // W16-g: turn boundary for tool threads (in-flight posts keep their captured thread).
        if let channelId = sessionMeta[handle]?.channelId {
            Task { await ToolActivityHost.shared.resetTurn(channelId: channelId) }
        }
        box.onAnswer?(pushResult)
        cont?.resume()
    }

    // MARK: - Lifecycle (W14)

    /// Hard-stop one channel's Claude session: cancel in-flight turn, `session.stop` RPC, drop
    /// session maps. Shared sidecar process stays up (other channels may still use it). Does NOT
    /// touch SessionRegistry / SessionStore — `SessionLifecycle` owns that.
    public func stop(channelId: String) async {
        stopEpoch[channelId, default: 0] += 1
        channelGates[channelId]?.cancel()
        channelGates[channelId] = nil
        turnDepth[channelId] = nil
        // Remove the handle before any `await` below: a concurrent `sessionHandle` reuse-path
        // call runs either fully before this method starts or only after this synchronous
        // prefix finishes (actor isolation doesn't yield until the first suspension point), so
        // there's no window where it can hand out a handle this stop() is about to tear down.
        let handle = sessions.removeValue(forKey: channelId)
        if let handle { sessionMeta[handle] = nil }
        await ToolActivityHost.shared.dispose(channelId: channelId)
        await StreamStatusHost.shared.dispose(channelId: channelId)
        await TaskPanelHost.shared.dispose(channelId: channelId)
        await UsageActivityHost.shared.dispose(channelId: channelId)
        // H5: cancel the idle watchdog on session teardown too (TS wiring.ts detach() calls
        // idleWatchdog.stop()) — previously only DabMain's own turn-completion path stopped it,
        // leaving an in-flight turn's timer armed when the session is killed out from under it.
        await IdleWatchdog.shared.stop(channelId: channelId)
        guard let handle else { return }
        // Unblock a waiter before the RPC so stop is never stuck on a hung turn. No-op once a
        // prior `.result` already answered (`finishWithError`'s own guard).
        finishWithError(handle: handle, error: SidecarRpcError(code: "interrupted", message: "session stopped"))
        turns[handle] = nil
        try? await client?.sessionStop(session: handle)
        client?.unregisterSessionHandlers(handle: handle)
    }

    /// Close and recreate the shared sidecar after the maintenance gate has drained all turns.
    /// Persisted bindings are retained and resume on their next request.
    @discardableResult
    public func restartRuntimeAfterUpdate() async -> Bool {
        guard !isAnyTurnRunning() else { return false }
        for channelId in Array(sessions.keys) {
            await stop(channelId: channelId)
        }
        if let client {
            await client.close()
            if self.client === client { self.client = nil }
        }
        do {
            let fresh = try await ensureClient()
            return !(try await fresh.claudeCatalog()).models.isEmpty
        } catch {
            log.warn("runtime update sidecar health failed: \(error)")
            return false
        }
    }

    /// Cancel the in-flight turn only (`session.interrupt`); keep the session handle so the next
    /// message continues. Returns `true` when a live session existed (TS orchestrator.interrupt).
    public func interrupt(channelId: String) async -> Bool {
        guard let handle = sessions[channelId] else { return false }
        try? await client?.sessionInterrupt(session: handle)
        if var box = turns[handle], !box.terminalStarted {
            if box.text.isEmpty { box.text = "(interrupted)" }
            deliverTerminal(handle: handle, box: &box)
        }
        return true
    }

    /// Live `session.setModel` on an open Claude session (TS orchestrator.setModel / W11-g).
    /// Returns `true` when a live handle accepted the RPC **or when there is no live session to
    /// apply to** — nothing to apply is not a failure, and the next `sessionHandle` start reads the
    /// persisted model (line 343). `false` means a live RPC actually failed, which is the only case
    /// `BindingUpdateResult.applyFailed` documents ("live session declined the switch").
    /// (binding layer still owns persistence — caller updates registry/store separately).
    @discardableResult
    public func setModel(channelId: String, model: String) async -> Bool {
        guard let handle = sessions[channelId], let client, !client.isClosed else { return true }
        do {
            try await client.sessionSetModel(session: handle, model: model)
            return true
        } catch {
            log.warn("session.setModel failed channel=\(channelId) model=\(model) error=\(error)")
            return false
        }
    }

    /// Live `session.setEffort` on an open Claude session. Same contract as `setModel`.
    @discardableResult
    public func setEffort(channelId: String, effort: String) async -> Bool {
        guard let handle = sessions[channelId], let client, !client.isClosed else { return true }
        do {
            try await client.sessionSetEffort(session: handle, effort: effort)
            return true
        } catch {
            log.warn("session.setEffort failed channel=\(channelId) effort=\(effort) error=\(error)")
            return false
        }
    }

    /// Runtime slash-command catalog for this channel's live Claude session (WO-2b, §3-5-3).
    ///
    /// No live session, a closed client, and a failed RPC all mean an empty list, never a throw:
    /// sessions spawn lazily on the first turn, so a channel that is bound but has not talked yet
    /// simply has nobody to ask, and the autocomplete caller must answer inside Discord's ~3s budget
    /// and cannot wait for a spawn. Same policy as `setModel(channelId:)` above, where "nothing to
    /// apply to" is success rather than failure — and the same shape as
    /// `CodexSessionBridge.slashCatalog` / `GrokSessionBridge.slashCatalog`.
    ///
    /// Deliberately uncached here: freshness is the autocomplete layer's TTL cache, shared by all
    /// three backends.
    public func slashCatalog(channelId: String) async -> [SlashCatalogEntry] {
        guard let handle = sessions[channelId], let client, !client.isClosed else { return [] }
        do {
            return try await client.claudeSlashCommands(session: handle)
        } catch {
            log.warn("claude.slashCommands failed channel=\(channelId) error=\(error)")
            return []
        }
    }

    /// Test/inspection: whether this channel still holds a live sidecar session handle.
    public func isLive(channelId: String) -> Bool {
        sessions[channelId] != nil
    }

    /// G-P1-05: open/resume the Claude session without a user turn. No-op when already live.
    /// Failures return false (caller keeps the registry bind; next message retries).
    @discardableResult
    public func softEnsure(
        channelId: String,
        guildId: String,
        ownerId: String?,
        config: SessionConfig?
    ) async -> Bool {
        if isLive(channelId: channelId) { return true }
        do {
            let client = try await ensureClient()
            _ = try await sessionHandle(
                client: client,
                channelId: channelId,
                guildId: guildId,
                ownerId: ownerId,
                config: config
            )
            return true
        } catch {
            log.warn("softEnsure failed channel=\(channelId) error=\(error)")
            return false
        }
    }
}

/// Full formatted tool input for the permission prompt (TS `permissionButtons.ts` formatInput +
/// truncate(…, 3000)). Reuses `formatToolInput` (Render/ToolFormat.swift) — same string/JSON-fence
/// shape the tool thread's opening message already uses.
private func permissionDetail(_ input: JSONValue) -> String? {
    DiscordText.truncate(formatToolInput(input), 3000)
}

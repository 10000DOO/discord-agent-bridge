import Foundation

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
            print("dab: spawning claude sidecar: \(spawn.command) \(spawn.args.joined(separator: " "))")
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
    private var channelGates: [String: Task<TurnResult, Error>] = [:]
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
        /// Turn-local tools/subagent HUD aggregates (W11-g slice4).
        var stats = TurnToolStatsAggregator()
        var done = false
        var continuation: CheckedContinuation<TurnResult, Error>?
        var timeoutTask: Task<Void, Never>?
    }

    /// Build TurnResult from the live box (tools/agents snapshotted at finish).
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
        let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 120
        return UInt64(max(5, sec)) * 1_000_000_000
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
        do {
            try await c.connect()
        } catch {
            // connect failed: close the spawned child so it does not leak as an orphan.
            await c.close()
            throw error
        }
        print("dab: sidecar ready (cwd=\(cwd) permMode=\(permMode))")
        self.client = c
        return c
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
            print("dab: sessions.list failed (\(error))")
            return []
        }
    }

    /// Send user text for a Discord channel; wait for accumulated text + result (or timeout).
    /// Turns on the same channel are serialized. Usage (cost/tokens/duration) from the result
    /// event is returned when present (W11-g slice1).
    /// `files` are confined workspace paths (G-P0-01) forwarded to sidecar `session.send`.
    public func runTurn(
        channelId: String,
        guildId: String,
        ownerId: String?,
        text: String,
        config: SessionConfig? = nil,
        files: [TurnFile] = []
    ) async throws -> TurnResult {
        // Read + install the gate with NO await between them, so a reentering job cannot install a
        // rival task against the same session. The previous turn is awaited INSIDE the task — that
        // is where serialization happens.
        let prev = channelGates[channelId]
        turnDepth[channelId, default: 0] += 1
        let task = Task { () -> TurnResult in
            if let prev { _ = try? await prev.value }
            return try await self.executeTurn(
                channelId: channelId,
                guildId: guildId,
                ownerId: ownerId,
                text: text,
                config: config,
                files: files
            )
        }
        channelGates[channelId] = task
        defer {
            turnDepth[channelId, default: 1] -= 1
            if turnDepth[channelId] == 0 { turnDepth[channelId] = nil }
            if channelGates[channelId] == task { channelGates[channelId] = nil }
        }
        var result = try await task.value
        // F5: prepend the resume-failure notice once, if this turn fell back to a fresh session.
        if let notice = fallbackNotice.removeValue(forKey: channelId) {
            result.text = notice + "\n\n" + result.text
        }
        return result
    }

    /// G-P2-04: any turn in-flight or waiting on this channel's gate chain.
    public func isTurnRunning(channelId: String) -> Bool {
        (turnDepth[channelId] ?? 0) > 0
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
        files: [TurnFile]
    ) async throws -> TurnResult {
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

        let timeoutNs = turnTimeoutNs
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TurnResult, Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard !Task.isCancelled else { return }
                self.finishTurn(handle: handle, error: nil, timeoutFallback: true)
            }
            turns[handle] = TurnBox(
                text: "",
                usage: nil,
                done: false,
                continuation: cont,
                timeoutTask: timeoutTask
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
        let perm = persisted?.permMode ?? config?.permMode ?? permMode
        let cwdValue = cwd

        // W16-f: prepareSession for custom — merge process env + allow-listed dotfile keys;
        // prefer ANTHROPIC_MODEL over wizard/ctx model (TS prepareCustomSession).
        var sessionEnv: [String: String?]?
        if backend == .custom {
            let resolved = resolveCustomEnvFn()
            if resolved.hasDangerousFlag, perm != "bypassPermissions" {
                print(
                    "dab: custom backend alias contains --dangerously-skip-permissions but permMode is not bypassPermissions source=\(resolved.source ?? "?")"
                )
            }
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in resolved.env { merged[k] = v }
            sessionEnv = merged.mapValues { Optional.some($0) }
            if let m = resolved.env["ANTHROPIC_MODEL"], !m.isEmpty {
                model = m
            }
            print(
                "dab: custom backend env resolved source=\(resolved.source ?? "nil") keys=\(resolved.env.keys.sorted())"
            )
        }

        // Thread the layered permission profile's allowedTools (+ global autoAllowClaudeTools
        // fallback) and permissionTimeoutSec into the sidecar (TS PermissionResolver.resolve() +
        // sessionOrchestrator.buildContext: modeConfig.allowedTools = modeConfig.autoAllowClaudeTools
        // = perm.allowedTools). Profiles are looked up from the top-level config only (never
        // server-layered, matching TS); permissionTimeoutSec IS server-layered via ConfigResolver.
        // A profile name that no longer exists in config.profiles (e.g. deleted after a channel
        // bound to it) falls back to the global auto-allow list rather than failing the turn —
        // TS throws here, but Swift prefers the fail-secure default already used elsewhere
        // (ConfigStore.autoAllowClaudeTools()) over killing a turn on a stale config reference.
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
        if let resumeId = persisted?.backendSessionId {
            do {
                started = try await client.sessionResume(params, backendSessionId: resumeId)
                print("dab: session.resume channel=\(channelId) backend=\(resumeId)")
            } catch {
                fallbackNotice[channelId] = sessionFallbackNotice
                started = try await client.sessionStart(params)
                print("dab: session.resume failed (\(error)) → start channel=\(channelId)")
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
                            model: persistModel, effort: effort, permMode: perm,
                            backendSessionId: backendId
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
                model: persistModel, effort: effort, permMode: perm,
                backendSessionId: bid
            )
        }
        if (stopEpoch[channelId] ?? 0) != epoch {
            sessions[channelId] = nil
            sessionMeta[handle] = nil
            client.unregisterSessionHandlers(handle: handle)
            try? await client.sessionStop(session: handle)
            throw SidecarRpcError(code: "interrupted", message: "session stopped")
        }
        print("dab: session.start channel=\(channelId) handle=\(handle)")
        return handle
    }

    private func onEvent(handle: String, event: AgentEvent) {
        guard var box = turns[handle], !box.done else { return }
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
            // Capture metrics for the done-line footer (W11-g slice1).
            if let u = turnUsage(fromResult: costUsd, tokensIn: tokensIn, tokensOut: tokensOut, durationMs: durationMs) {
                box.usage = u
            }
            turns[handle] = box
            let out = box.text.isEmpty ? "(empty result)" : box.text
            finishTurnUnlocked(handle: handle, result: makeTurnResult(box: box, text: out))
        case .contextUsage:
            // W11-g slice2: keep latest context_usage for the turn result / panel.
            if let info = ContextUsageInfo.from(event: event) {
                box.contextUsage = info
                turns[handle] = box
            }
        case .rateLimit(let resetAt, let rateLimitType, let utilization):
            // W11-g slice2: capture rate_limit for a post-turn notice line.
            box.rateLimit = RateLimitInfo(
                resetAt: resetAt,
                rateLimitType: rateLimitType,
                utilization: utilization
            )
            turns[handle] = box
        case .error(let message, _):
            finishTurnUnlocked(
                handle: handle,
                result: nil,
                error: SidecarRpcError(code: "sdk_error", message: message)
            )
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
        guard let box = turns[handle], !box.done else { return }
        if let error {
            finishTurnUnlocked(handle: handle, result: nil, error: error)
            return
        }
        if timeoutFallback {
            if box.text.isEmpty {
                finishTurnUnlocked(
                    handle: handle,
                    result: nil,
                    error: SidecarRpcError(
                        code: "internal",
                        message: "turn timeout (no text)",
                        retryable: true
                    )
                )
            } else {
                finishTurnUnlocked(
                    handle: handle,
                    result: makeTurnResult(box: box, text: box.text + "\n…(timeout)")
                )
            }
        }
    }

    private func finishTurnUnlocked(handle: String, result: TurnResult?, error: Error? = nil) {
        guard var box = turns[handle], !box.done else { return }
        box.done = true
        box.timeoutTask?.cancel()
        let cont = box.continuation
        box.continuation = nil
        box.timeoutTask = nil
        turns[handle] = box
        // W16-g: turn boundary for tool threads (in-flight posts keep their captured thread).
        if let channelId = sessionMeta[handle]?.channelId {
            Task { await ToolActivityHost.shared.resetTurn(channelId: channelId) }
        }
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: result ?? makeTurnResult(box: box, text: box.text))
        }
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
        await ToolActivityHost.shared.dispose(channelId: channelId)
        await StreamStatusHost.shared.dispose(channelId: channelId)
        guard let handle = sessions.removeValue(forKey: channelId) else { return }
        sessionMeta[handle] = nil
        // Unblock a waiter before the RPC so stop is never stuck on a hung turn.
        if let box = turns[handle], !box.done {
            finishTurnUnlocked(
                handle: handle,
                result: nil,
                error: SidecarRpcError(code: "interrupted", message: "session stopped")
            )
        }
        turns[handle] = nil
        try? await client?.sessionStop(session: handle)
        client?.unregisterSessionHandlers(handle: handle)
    }

    /// Cancel the in-flight turn only (`session.interrupt`); keep the session handle so the next
    /// message continues. Returns `true` when a live session existed (TS orchestrator.interrupt).
    public func interrupt(channelId: String) async -> Bool {
        guard let handle = sessions[channelId] else { return false }
        try? await client?.sessionInterrupt(session: handle)
        if let box = turns[handle], !box.done {
            let partial = box.text.isEmpty ? "(interrupted)" : box.text
            finishTurnUnlocked(handle: handle, result: makeTurnResult(box: box, text: partial))
        }
        return true
    }

    /// Live `session.setModel` on an open Claude session (TS orchestrator.setModel / W11-g).
    /// Returns `true` when a live handle accepted the RPC; `false` when no session or RPC failed
    /// (binding layer still owns persistence — caller updates registry/store separately).
    @discardableResult
    public func setModel(channelId: String, model: String) async -> Bool {
        guard let handle = sessions[channelId], let client, !client.isClosed else { return false }
        do {
            try await client.sessionSetModel(session: handle, model: model)
            return true
        } catch {
            return false
        }
    }

    /// Live `session.setEffort` on an open Claude session. Same contract as `setModel`.
    @discardableResult
    public func setEffort(channelId: String, effort: String) async -> Bool {
        guard let handle = sessions[channelId], let client, !client.isClosed else { return false }
        do {
            try await client.sessionSetEffort(session: handle, effort: effort)
            return true
        } catch {
            return false
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
            print("dab: softEnsure failed channel=\(channelId) error=\(error)")
            return false
        }
    }
}

/// Short human hint for the permission button message (e.g. the shell command). Best-effort.
private func permissionDetail(_ input: JSONValue) -> String? {
    if let c = input["command"]?.stringValue, !c.isEmpty { return c }
    if let p = input["file_path"]?.stringValue, !p.isEmpty { return p }
    return nil
}

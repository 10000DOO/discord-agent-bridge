import Foundation

private let log = Logger(name: "grok")

/// Sibling of `CodexSessionBridge` for the minimal `!grok` path (W10-c3). One `grok agent stdio`
/// child per channel; per-channel turn serialization.
///
/// Unlike Codex (turn completes on a `turn/completed` notification, so the bridge waits on a
/// continuation), Grok completes a turn when `sessionPrompt` RETURNS (it blocks on the
/// session/prompt response). Text arrives on `onNotification` meanwhile; the read loop dispatches
/// those handlers synchronously BEFORE it resumes the prompt response, so a synchronous fold into a
/// lock buffer is complete at return. Control RPC uses a 60s client timeout; the **turn budget**
/// (`DAB_TURN_TIMEOUT_SEC`, default 120) is enforced here by racing `sessionPrompt` (close child on
/// expiry). Do NOT hop onto the actor from the notification handler (a Task would run after return).
public actor GrokSessionBridge {
    public static let shared = GrokSessionBridge()

    /// Client factory (test seam). Grok's model/effort AND bypass are SPAWN-time flags, so the factory
    /// takes the channel's SessionConfig to build the spawn (TS parity: no live setModel/setEffort).
    /// The permission handler is also construction-time, so it is passed too, along with the
    /// per-spawn `mcpServers` (C5: attach_file/share_document loopback — built fresh per (re)spawn
    /// by `buildMcpServers`, empty when the attach gateway/hosts are unreachable). `@testable` in tests.
    private let makeClient: @Sendable (SessionConfig?, _ onPermission: AcpPermissionHandler?, _ mcpServers: [AcpMcpServerConfig]) throws -> GrokAcpClient
    /// Test seam: override the turn timeout (default nil → DAB_TURN_TIMEOUT_SEC env, floor 5s).
    private let turnTimeoutOverrideNs: UInt64?
    /// Permission gate (default shared; tests inject a fresh gate for isolation).
    private let gate: PermissionGate
    /// Global config (autoAllowClaudeTools host-side check for Always-Allow).
    private let configStore: ConfigStore
    /// Loopback attach_file/share_document gateway (default shared; tests inject a no-socket
    /// fake — see `GrokAttachGatewayProviding`).
    private let attachGateway: any GrokAttachGatewayProviding
    /// Model catalog / context-window source (C7; default shared; tests inject a fake so the
    /// usage-panel lookup never touches the real `~/.grok/models_cache.json`).
    private let configSource: GrokConfigSource

    init(
        makeClient: @escaping @Sendable (SessionConfig?, _ onPermission: AcpPermissionHandler?, _ mcpServers: [AcpMcpServerConfig]) throws -> GrokAcpClient = { config, onPermission, mcpServers in
            // W11-c: bypass (`--always-approve`) only when the permMode is an auto-approve one; else
            // grok emits permission asks answered via the Discord gate (onPermission). model/effort
            // from the bound config. No permMode bound → bypass (danger default parity).
            let bypass = grokBypassPermMode(config?.permMode)
            // Drop a leaked non-grok model id from `-m` (TS isGrokModel). Catalog
            // `isKnownModel` is actor-isolated; spawn is sync — use name heuristic here.
            // (Full catalog inject: resolveGrokSpawn(isGrokModel:).)
            let spawn = resolveGrokSpawn(
                model: config?.model,
                effort: config?.effort,
                bypassPermissions: bypass,
                isGrokModel: { $0.lowercased().contains("grok") }
            )
            log.info("spawning grok agent stdio: \(spawn.command) \(spawn.args.joined(separator: " "))")
            // Control-request timeout only (60s). Turn budget is bridge-owned (sessionPrompt has none).
            // M6/WO-13: augment the child's PATH with well-known nvm/fnm/volta dirs (mirrors
            // CodexSessionBridge's codexChildEnvironment() wiring below).
            return try GrokAcpClient(spawn: spawn, requestTimeoutMs: 60_000, environment: grokChildEnvironment(), mcpServers: mcpServers, onPermission: onPermission)
        },
        turnTimeoutOverrideNs: UInt64? = nil,
        gate: PermissionGate = .shared,
        store: SessionStore = .shared,
        configStore: ConfigStore = .shared,
        attachGateway: any GrokAttachGatewayProviding = GrokAttachGateway.shared,
        configSource: GrokConfigSource = .shared
    ) {
        self.makeClient = makeClient
        self.turnTimeoutOverrideNs = turnTimeoutOverrideNs
        self.gate = gate
        self.store = store
        self.configStore = configStore
        self.attachGateway = attachGateway
        self.configSource = configSource
    }

    /// Session persistence (default shared; tests inject a temp-file store).
    private let store: SessionStore
    /// One-shot resume-failure notice to prepend to the next reply (F5).
    private var fallbackNotice: [String: String] = [:]

    private struct Channel {
        let client: GrokAcpClient
        /// Spawn flags this child was launched with. Grok has no live setModel/setEffort, so a
        /// `/model` or `/effort` that lands on the binding only takes effect on a respawn:
        /// `ensureChannel` compares this against the current config and relaunches (session/load
        /// keeps the conversation) instead of silently answering with the old model.
        let spawnKey: String
    }

    /// Spawn-time fields only (`-m` / `--reasoning-effort` in `resolveGrokSpawn`). permMode is
    /// deliberately excluded: `/perm` changing `--always-approve` mid-session is a separate call.
    private func spawnKey(_ config: SessionConfig?) -> String {
        "\(config?.model ?? "")|\(config?.effort ?? "")"
    }

    /// channelId (snowflake string) → grok client (holds its own sessionId)
    private var channels: [String: Channel] = [:]
    /// channelId → epoch bumped on `stop` so ensureChannel that races mid-await closes the orphan.
    private var stopEpoch: [String: UInt64] = [:]
    /// Serialize turns per channel (avoid concurrent sessionPrompt on the same session).
    private var channelGates: [String: Task<TurnResult, Error>] = [:]
    /// Per-channel count of `runTurn` callers (in-flight + waiting). G-P2-04 stats.
    private var turnDepth: [String: Int] = [:]
    /// channelId → live attach-gateway token (C5). Survives a `Channel` respawn (interrupt /
    /// dead child) so `buildMcpServers` can drop the stale registration before issuing a fresh
    /// one — mirrors TS GrokAcpSession's instance-level `this.attachToken`.
    private var attachTokens: [String: String] = [:]

    // env rules copied from CodexSessionBridge (B/"sibling bridge": no forced sharing).
    private var cwd: String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["DAB_CWD"], !v.isEmpty { return v }
        return NSHomeDirectory()
    }

    private var turnTimeoutNs: UInt64 {
        if let turnTimeoutOverrideNs { return turnTimeoutOverrideNs }
        let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 10_800
        return UInt64(max(5, sec)) * 1_000_000_000
    }

    /// Send user text for a Discord channel; wait for the prompt turn + accumulated text.
    /// Turns on the same channel are serialized. Cost/tokens from the prompt response are
    /// returned when present (W11-g slice1).
    /// `files`: images go out as ACP `image` blocks (base64), everything else as a text hint
    /// (`buildGrokPromptBlocks`, TS `acpSession.ts:431-441` parity).
    public func runTurn(channelId: String, ownerId: String? = nil, guildId: String = "", text: String, config: SessionConfig? = nil, files: [TurnFile] = []) async throws -> TurnResult {
        if !(await ProviderRuntimeMaintenanceGate.shared.reserveTurnIfAvailable()) {
            await ProviderRuntimeMaintenanceGate.shared.reserveTurn()
        }
        defer { Task { await ProviderRuntimeMaintenanceGate.shared.releaseTurn() } }
        // Read + install the gate with NO await between them, so a reentering job cannot install a
        // rival task against the same session (buffer/session cross-talk). The previous turn is
        // awaited INSIDE the task — that is where serialization happens.
        let prev = channelGates[channelId]
        turnDepth[channelId, default: 0] += 1
        let task = Task { () -> TurnResult in
            if let prev { _ = try? await prev.value }
            return try await self.executeTurn(channelId: channelId, ownerId: ownerId, guildId: guildId, text: text, config: config, files: files)
        }
        channelGates[channelId] = task
        defer {
            turnDepth[channelId, default: 1] -= 1
            if turnDepth[channelId] == 0 { turnDepth[channelId] = nil }
            if channelGates[channelId] == task { channelGates[channelId] = nil }
        }
        var result = try await task.value
        if let notice = fallbackNotice.removeValue(forKey: channelId) {
            result.text = notice + "\n\n" + result.text
        }
        return result
    }

    /// G-P2-04: any turn in-flight or waiting on this channel's gate chain.
    public func isTurnRunning(channelId: String) -> Bool {
        (turnDepth[channelId] ?? 0) > 0
    }

    public func isAnyTurnRunning() -> Bool {
        turnDepth.values.contains { $0 > 0 }
    }

    /// Provider maintenance has already reserved the turn gate.  Idle ACP children must be
    /// recreated so a subsequent turn executes the newly installed Grok binary.
    public func restartRuntimeAfterUpdate() async -> Bool {
        guard !isAnyTurnRunning() else { return false }
        let held = channels
        channels.removeAll()
        for channel in held.values { await channel.client.close() }
        return true
    }

    /// G-P2-04: turns waiting behind the running one (TS `queueDepth`).
    public func turnQueueDepth(channelId: String) -> Int {
        max(0, (turnDepth[channelId] ?? 0) - 1)
    }

    /// WO-3: slash commands the live grok session advertises (`available_commands_update`, captured
    /// by `GrokAcpClient` itself — see its `availableCommands`).
    ///
    /// No live session → EMPTY, not an error. Sessions spawn lazily on the first turn, so a channel
    /// that is bound but has not talked yet simply has nobody to ask; the autocomplete caller must
    /// answer inside Discord's ~3s budget and cannot wait for a spawn. Same policy as
    /// `DabSessionBridge.setModel(channelId:)`, where "nothing to apply to" is success, not failure.
    public func slashCatalog(channelId: String) -> [SlashCatalogEntry] {
        channels[channelId]?.client.availableCommands ?? []
    }

    private func executeTurn(channelId: String, ownerId: String?, guildId: String, text: String, config: SessionConfig?, files: [TurnFile]) async throws -> TurnResult {
        let channel = try await ensureChannel(channelId: channelId, config: config, ownerId: ownerId, guildId: guildId)
        // Multimodal: images → ACP `image` blocks (base64); everything else → text hint.
        let promptBlocks = try buildGrokPromptBlocks(text: text, files: files)

        // Synchronous fold: the read loop runs this handler before resuming sessionPrompt, so the
        // buffer is complete when the await returns (see type comment). No actor hop for text/stats;
        // ToolActivityHost is an actor → fire-and-forget Task for Discord threads (Claude parity).
        let buf = LockedBox("")
        let statsBox = LockedBox(TurnToolStatsAggregator())
        let idSeq = LockedBox(0)

        // WO-2: hang-timeout watchdog, rearmed on every notification (any kind) instead of a fixed
        // countdown from turn start. `scheduleTimeout()` cancels any pending timer and starts a
        // fresh one of the same length; firing just closes the client, which unblocks the awaited
        // `sessionPrompt` below with an error — no separate racing task needed (unlike the old
        // `withThrowingTaskGroup` race against a one-shot sleep).
        let timeoutNs = turnTimeoutNs
        let timeoutSec = Int(timeoutNs / 1_000_000_000)
        let timedOut = LockedBox(false)
        let client = channel.client
        let timeoutTaskBox = LockedBox<Task<Void, Never>?>(nil)
        let scheduleTimeout: @Sendable () -> Void = {
            let next = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard !Task.isCancelled else { return }
                timedOut.withLock { $0 = true }
                await client.close()
            }
            timeoutTaskBox.withLock { $0?.cancel(); $0 = next }
        }
        defer { timeoutTaskBox.withLock { $0?.cancel() } }
        scheduleTimeout()

        let unsub = channel.client.onNotification { method, params in
            scheduleTimeout()
            if case .appendText(let delta) = grokUpdateStep(method: method, params: params) {
                buf.withLock { $0 += delta }
                // W11-g residual: live stream text.
                let ch = channelId
                Task { await StreamStatusHost.shared.noteText(channelId: ch, delta: delta) }
            }
            // W16-g / G-P0-03: agent_thought_chunk → thinking stream (purple); plan → progress.
            // Thought is not part of the reply buffer (TS thinking stream).
            let ch = channelId
            // WO-3: a plan update feeds the pinned task panel. When it does, the same list must NOT
            // also be appended to the stream body — one list, one place (docs 8장 중복 표시).
            let planItems = grokPlanItems(method: method, params: params)
            if let planItems {
                Task { await TaskPanelHost.shared.noteItems(channelId: ch, items: planItems) }
            }
            for pev in grokProgressEvents(method: method, params: params) {
                switch pev {
                case .thinking(let text, _):
                    Task { await StreamStatusHost.shared.noteThinking(channelId: ch, delta: text) }
                case .progress(let label, let detail):
                    guard planItems == nil else { break }
                    Task {
                        await StreamStatusHost.shared.noteProgress(
                            channelId: ch, label: label, detail: detail
                        )
                    }
                default:
                    break
                }
            }
            // W16-g residual: tool_call / tool_call_update → stats + Discord work threads.
            let toolEvs = idSeq.withLock { seq -> [AgentEvent] in
                grokToolEvents(method: method, params: params, mintId: &seq)
            }
            if !toolEvs.isEmpty {
                statsBox.withLock { s in
                    for ev in toolEvs { s.note(ev) }
                }
                for ev in toolEvs {
                    Task { await ToolActivityHost.shared.handle(channelId: ch, event: ev) }
                    if case .toolUse = ev {
                        Task { await StreamStatusHost.shared.noteToolUse(channelId: ch) }
                    }
                }
            }
        }
        defer { unsub() }

        // Bridge owns the turn budget (`scheduleTimeout` above). A timeout closes the client,
        // which unblocks this await with a "client was closed" error — translate that into the
        // same timeout error message the old racing implementation threw.
        let promptResult: JSONValue
        do {
            promptResult = try await client.sessionPrompt(blocks: promptBlocks)
        } catch {
            if timedOut.withLock({ $0 }) {
                // Drop closed client so the next turn respawns cleanly.
                if let held = channels[channelId], held.client === client {
                    channels[channelId] = nil
                }
                throw AcpClientError("grok turn timed out after \(timeoutSec)s.")
            }
            throw error
        }
        let out = buf.withLock { $0 }
        let (tools, agents) = statsBox.withLock { ($0.toolsSnapshot(), $0.agentsSnapshot()) }
        // W16-g: turn boundary for tool threads.
        await ToolActivityHost.shared.resetTurn(channelId: channelId)
        // C7: model → this session's bound model, else the response's own modelId, else the
        // catalog default (TS acpSession.ts:387 `this.model.length > 0 ? this.model : result?.modelId
        // ?? grokConfigSource.defaultModel()`).
        let (rawTotalTokens, resultModelId) = grokContextUsageInputs(fromPromptResult: promptResult)
        let sessionModel = (config?.model).flatMap { $0.isEmpty ? nil : $0 }
        let model: String
        if let sessionModel {
            model = sessionModel
        } else if let resultModelId {
            model = resultModelId
        } else {
            model = await configSource.defaultModel()
        }
        let maxTokens = await configSource.contextWindow(model)
        // TODO(DAB-DIAG-GROK-CTX): temporary diagnostic log for docs/grok-context-usage-panel-missing.md
        // WO-1 — remove once H1/H2/H3 are confirmed from real Grok session output.
        log.info("[DAB-DIAG-GROK-CTX] rawTotalTokens=\(String(describing: rawTotalTokens)) resultModelId=\(String(describing: resultModelId)) model=\(model) maxTokens=\(String(describing: maxTokens))")
        // `/context` sends nothing back over ACP, so its screen is rebuilt from the facts just
        // computed above; every other empty turn keeps the plain stand-in.
        let screen = out.isEmpty
            ? grokLocalCommandScreen(prompt: text, model: model, totalTokens: rawTotalTokens, maxTokens: maxTokens)
            : nil
        let textOut = out.isEmpty ? (screen ?? "(no text)") : out
        return TurnResult(
            text: textOut,
            usage: turnUsage(fromGrokPromptResult: promptResult),
            contextUsage: grokContextUsage(totalTokens: rawTotalTokens, model: model, maxTokens: maxTokens),
            tools: tools,
            agents: agents
        )
    }

    private func ensureChannel(channelId: String, config: SessionConfig?, ownerId: String?, guildId: String) async throws -> Channel {
        // Reuse a live client; a closed one (crashed/EOF) or one spawned with stale model/effort
        // flags is dropped and respawned (mirrors CodexSessionBridge.ensureChannel).
        if let existing = channels[channelId] {
            if !existing.client.isClosed, existing.spawnKey == spawnKey(config) {
                return existing
            }
            await existing.client.close()
            channels[channelId] = nil
        }
        let epoch = stopEpoch[channelId] ?? 0
        // ponytail: model/effort/bypass are spawn flags (Grok has no live setModel/setEffort), so a
        // changed model/effort respawns via `spawnKey` above. A later /perm change still needs a
        // manual respawn (W11-c+).
        let persisted = await store.binding(channelId: channelId)
        let cwdValue = persisted?.cwd ?? cwd
        var startedFresh = persisted?.backendSessionId == nil

        // H8: a profile name persisted on the binding is the source of truth for permissionMode —
        // re-resolve it from the LIVE config here rather than trusting the (possibly stale)
        // stored/bound value, so an operator's edit to profiles.<name>.permissionMode takes effect
        // on the next session start/resume without a `/mode perm` round-trip (TS
        // permissionResolver.resolve()). M2 (WO-15): a bound profile that no longer exists in config
        // blocks the session instead of silently falling back to the stale value (TS
        // permissionResolver.ts:66-70 throws `Unknown permission profile`) — mirrors
        // DabSessionBridge (WO-4) / CodexSessionBridge (WO-1), closing the backend parity gap RV
        // flagged. Same fail-secure treatment when config.json itself is missing/unreadable as the
        // other two bridges: the stale/persisted value stands rather than throwing the turn.
        var effectiveConfig = config
        if let globalConfig = try? await configStore.load(), let profileName = persisted?.permissionProfile {
            guard let profile = globalConfig.profiles[profileName] else {
                throw AcpClientError("Unknown permission profile '\(profileName)'.")
            }
            var patched = config ?? SessionConfig(backend: .grok)
            patched.permMode = profile.permissionMode
            effectiveConfig = patched
            // This is an explicit live-profile resolution at session start, not the later backend
            // id callback. Persist it before the callback so `persistSession` can remain limited
            // to publishing the backend session id and cannot overwrite a concurrent binding edit.
            if var current = persisted, current.permMode != profile.permissionMode {
                current.permMode = profile.permissionMode
                current.updatedAt = iso8601Now()
                try? await store.upsert(channelId: channelId, current)
            }
        }

        // W11-c: bypass permMode → `--always-approve` (no handler). Non-bypass → route grok's
        // permission asks through the Discord gate (onPermission); waits forever if unanswered.
        let gate = self.gate
        let onPermission: AcpPermissionHandler?
        if grokBypassPermMode(effectiveConfig?.permMode) {
            onPermission = nil   // `--always-approve`: grok never asks
        } else {
            let configStore = self.configStore
            onPermission = { req in
                let toolName = req.toolName ?? "tool"
                // W16-e: always-allowed tools skip the Discord button.
                if await isAutoAllowedClaudeTool(toolName, store: configStore) {
                    return .allow
                }
                let decision = await gate.await(
                    prompt: PermissionPrompt(
                        reqKey: UUID().uuidString,
                        channelId: channelId,
                        toolName: toolName,
                        approverId: ownerId
                    )
                )
                return decision.isAllowing ? .allow : .deny   // always|allow → allow; deny-by-default
            }
        }
        // C5: fresh attach_file/share_document MCP registration for this (re)spawn only —
        // the early-return-if-live path above never rebuilds it (TS ensureClient parity).
        let mcpServers = try await buildMcpServers(channelId: channelId, cwd: cwdValue)
        let client = try makeClient(effectiveConfig, onPermission, mcpServers)

        do {
            _ = try await client.initialize()
            // W11-f2: load the stored session if any; on failure start a fresh one (F5).
            if let resumeId = persisted?.backendSessionId {
                do {
                    try await client.sessionLoad(sessionId: resumeId, cwd: cwdValue)
                    log.info("session/load channel=\(channelId) sid=\(resumeId)")
                } catch {
                    fallbackNotice[channelId] = sessionFallbackNotice()
                    _ = try await client.sessionNew(cwd: cwdValue)
                    startedFresh = true
                    log.warn("load failed (\(error)) → session/new channel=\(channelId)")
                }
            } else {
                _ = try await client.sessionNew(cwd: cwdValue)
            }
        } catch {
            // Init failed: close the spawned child so it does not leak as an orphan.
            await client.close()
            throw error
        }

        if (stopEpoch[channelId] ?? 0) != epoch {
            await client.close()
            throw AcpClientError("session stopped")
        }

        let channel = Channel(client: client, spawnKey: spawnKey(effectiveConfig))
        channels[channelId] = channel
        // F7: capture the grok session id + live context.
        await persistSession(store: store, backend: .grok, channelId: channelId, guildId: guildId, ownerId: ownerId, cwd: cwdValue, model: effectiveConfig?.model, effort: effectiveConfig?.effort, permMode: effectiveConfig?.permMode, backendSessionId: client.sessionId, lifecycleGeneration: persisted?.lifecycleGeneration, contextGenerationStartedAt: startedFresh ? iso8601Now() : nil)
        if (stopEpoch[channelId] ?? 0) != epoch {
            channels[channelId] = nil
            await client.close()
            throw AcpClientError("session stopped")
        }
        log.info("session channel=\(channelId) sid=\(client.sessionId ?? "?")")
        return channel
    }

    // MARK: - Attach gateway (C5)

    /// Registers a fresh loopback token for this channel's next spawn and returns the "discord"
    /// MCP server config Grok should be told to launch (mirrors TS acpSession.ts buildMcpServers
    /// 1:1). The subprocess is `dab` itself, re-invoked with the hidden `attach-mcp` subcommand
    /// (DabMain dispatches it before the bot-boot path) — no second compiled binary, no Node.
    private func buildMcpServers(channelId: String, cwd: String) async throws -> [AcpMcpServerConfig] {
        try await attachGateway.whenReady()
        // Fresh token per spawn so a re-init after interrupt still has a live registration; the
        // stale one from the previous spawn (if any) is dropped first.
        if let stale = attachTokens[channelId] {
            await attachGateway.unregister(token: stale)
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        await attachGateway.register(token: token, channelId: channelId, workspaceRoot: cwd)
        attachTokens[channelId] = token
        return [
            AcpMcpServerConfig(
                name: "discord",
                command: dabSelfExecutablePath(),
                args: ["attach-mcp"],
                env: [
                    AcpMcpEnvVar(name: "DAB_ATTACH_URL", value: await attachGateway.baseURL),
                    AcpMcpEnvVar(name: "DAB_ATTACH_TOKEN", value: token),
                    AcpMcpEnvVar(name: "DAB_WORKSPACE", value: cwd),
                ]
            )
        ]
    }

    private func unregisterAttach(channelId: String) async {
        guard let token = attachTokens.removeValue(forKey: channelId) else { return }
        await attachGateway.unregister(token: token)
    }

    // MARK: - Lifecycle (W14)

    /// Hard-stop: close the grok child and drop the live channel entry (TS GrokAcpSession.stop).
    /// SessionStore resume id is left for `SessionLifecycle` to remove. Does NOT touch registry/store.
    public func stop(channelId: String) async {
        stopEpoch[channelId, default: 0] += 1
        channelGates[channelId]?.cancel()
        channelGates[channelId] = nil
        turnDepth[channelId] = nil
        // Remove the channel entry before any `await` below: a concurrent `ensureChannel`
        // reuse-path call runs either fully before this method starts or only after this
        // synchronous prefix finishes (actor isolation doesn't yield until the first suspension
        // point), so there's no window where it can hand out a channel this stop() is tearing down.
        let ch = channels.removeValue(forKey: channelId)
        await ToolActivityHost.shared.dispose(channelId: channelId)
        await StreamStatusHost.shared.dispose(channelId: channelId)
        await TaskPanelHost.shared.dispose(channelId: channelId)
        await UsageActivityHost.shared.dispose(channelId: channelId)
        await IdleWatchdog.shared.stop(channelId: channelId)
        await unregisterAttach(channelId: channelId)
        guard let ch else { return }
        await ch.client.close()
    }

    /// Cancel the current turn by dropping the client process while keeping SessionStore's resume
    /// id so the next turn `session/load`s the same conversation (TS GrokAcpSession.interrupt =
    /// dropClient; ACP wire has no session/cancel — do not invent one).
    /// Returns `true` when a live client existed.
    public func interrupt(channelId: String) async -> Bool {
        guard let ch = channels.removeValue(forKey: channelId) else { return false }
        // Closing fails any in-flight session/prompt so the gate task unblocks.
        await ch.client.close()
        return true
    }

    /// Test/inspection: whether this channel still holds a live grok client.
    public func isLive(channelId: String) -> Bool {
        channels[channelId] != nil
    }

    /// G-P1-05: open/resume the Grok ACP session without a user turn. No-op when already live.
    @discardableResult
    public func softEnsure(
        channelId: String,
        guildId: String,
        ownerId: String?,
        config: SessionConfig?
    ) async -> Bool {
        if isLive(channelId: channelId) { return true }
        do {
            _ = try await ensureChannel(
                channelId: channelId,
                config: config,
                ownerId: ownerId,
                guildId: guildId
            )
            return true
        } catch {
            log.warn("softEnsure failed channel=\(channelId) error=\(error)")
            return false
        }
    }
}

/// Multimodal prompt: text + base64 images (ACP `image` block, `grok agent stdio`).
/// Mirrors TS `buildGrokPromptBlocks` (`acpSession.ts:431-441`).
func buildGrokPromptBlocks(text: String, files: [TurnFile]) throws -> [AcpPromptBlock] {
    let classified = classifyTurnFiles(files)
    let images = classified.filter { $0.isImage }
    let nonImages = classified.filter { !$0.isImage }
    let hinted = appendAttachedFileHints(text: text, files: nonImages.map { TurnFile(path: $0.path, mime: $0.mime) })
    var blocks: [AcpPromptBlock] = [.text(hinted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : hinted)]
    for img in images {
        blocks.append(.image(data: try readImageBase64(path: img.path), mimeType: img.mime))
    }
    return blocks
}

/// Whether a permMode auto-approves for Grok (→ `--always-approve`, no permission UI). M7: no bound
/// permMode → false (safe default; approval required) — TS `sessionOrchestrator.ts:817` defaults an
/// unbound session to `'default'`, not an auto-approve mode. The normal wizard/preset start path
/// always sets a non-empty permMode (`ChannelWizard` seeds `options.defaults.permMode`, falls back
/// further to `"default"`), so this branch is only reached by a channel with no permMode ever bound
/// (e.g. a pre-permMode legacy import) — never by a freshly wizard-started session.
func grokBypassPermMode(_ permMode: String?) -> Bool {
    guard let permMode, !permMode.isEmpty else { return false }
    return permMode == "bypassPermissions" || permMode == "danger-full-access"
}

/// Absolute path to the running `dab` binary itself — reused as the attach_file/share_document
/// MCP subprocess via `dab attach-mcp` (C5). `grok agent stdio` spawns this as ITS OWN child, so
/// a relative path would resolve against grok's inherited cwd, not ours — hence the absolute-path
/// normalization here rather than passing `CommandLine.arguments[0]` straight through.
func dabSelfExecutablePath() -> String {
    let arg0 = CommandLine.arguments.first ?? "dab"
    if arg0.hasPrefix("/") { return arg0 }
    return FileManager.default.currentDirectoryPath + "/" + arg0
}

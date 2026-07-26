import Foundation

/// Sibling of `CodexSessionBridge` for the minimal `!grok` path (W10-c3). One `grok agent stdio`
/// child per channel; per-channel turn serialization.
///
/// Unlike Codex (turn completes on a `turn/completed` notification, so the bridge waits on a
/// continuation), Grok completes a turn when `sessionPrompt` RETURNS (it blocks on the
/// session/prompt response). Text arrives on `onNotification` meanwhile; the read loop dispatches
/// those handlers synchronously BEFORE it resumes the prompt response (AcpClient.swift:280-291,
/// 337-340, 386-391, 343-352), so a synchronous fold into a lock buffer is complete at return —
/// no continuation / TurnBox / timeout task needed here (the client's requestTimeoutMs owns the
/// turn budget). Do NOT hop onto the actor from the handler (a Task would run after the return).
public actor GrokSessionBridge {
    public static let shared = GrokSessionBridge()

    /// Client factory (test seam). Grok's model/effort AND bypass are SPAWN-time flags, so the factory
    /// takes the channel's SessionConfig to build the spawn (TS parity: no live setModel/setEffort).
    /// The permission handler is also construction-time, so it is passed too. `@testable` in tests.
    private let makeClient: @Sendable (SessionConfig?, _ onPermission: AcpPermissionHandler?) throws -> GrokAcpClient
    /// Permission gate (default shared; tests inject a fresh gate for isolation).
    private let gate: PermissionGate
    /// Global config (autoAllowClaudeTools host-side check for Always-Allow).
    private let configStore: ConfigStore

    init(
        makeClient: @escaping @Sendable (SessionConfig?, _ onPermission: AcpPermissionHandler?) throws -> GrokAcpClient = { config, onPermission in
            let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 120
            // W11-c: bypass (`--always-approve`) only when the permMode is an auto-approve one; else
            // grok emits permission asks answered via the Discord gate (onPermission). model/effort
            // from the bound config. No permMode bound → bypass (danger default parity).
            let bypass = grokBypassPermMode(config?.permMode)
            let spawn = resolveGrokSpawn(model: config?.model, effort: config?.effort, bypassPermissions: bypass)
            print("dab: spawning grok agent stdio: \(spawn.command) \(spawn.args.joined(separator: " "))")
            return try GrokAcpClient(spawn: spawn, requestTimeoutMs: max(5, sec) * 1000, onPermission: onPermission)
        },
        gate: PermissionGate = .shared,
        store: SessionStore = .shared,
        configStore: ConfigStore = .shared
    ) {
        self.makeClient = makeClient
        self.gate = gate
        self.store = store
        self.configStore = configStore
    }

    /// Session persistence (default shared; tests inject a temp-file store).
    private let store: SessionStore
    /// One-shot resume-failure notice to prepend to the next reply (F5).
    private var fallbackNotice: [String: String] = [:]

    private struct Channel {
        let client: GrokAcpClient
    }

    /// channelId (snowflake string) → grok client (holds its own sessionId)
    private var channels: [String: Channel] = [:]
    /// channelId → epoch bumped on `stop` so ensureChannel that races mid-await closes the orphan.
    private var stopEpoch: [String: UInt64] = [:]
    /// Serialize turns per channel (avoid concurrent sessionPrompt on the same session).
    private var channelGates: [String: Task<TurnResult, Error>] = [:]

    // env rules copied from CodexSessionBridge (B/"sibling bridge": no forced sharing).
    private var cwd: String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["DAB_CWD"], !v.isEmpty { return v }
        return NSHomeDirectory()
    }

    // ponytail: permission-button deadline < the turn budget (client requestTimeoutMs) so an
    // unanswered ask denies before the sessionPrompt request itself times out.
    private var permGateTimeoutNs: UInt64 {
        let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 120
        return UInt64(max(5, sec)) * 1_000_000_000 / 2
    }

    /// Send user text for a Discord channel; wait for the prompt turn + accumulated text.
    /// Turns on the same channel are serialized. Cost/tokens from the prompt response are
    /// returned when present (W11-g slice1).
    public func runTurn(channelId: String, ownerId: String? = nil, guildId: String = "", text: String, config: SessionConfig? = nil) async throws -> TurnResult {
        // Read + install the gate with NO await between them, so a reentering job cannot install a
        // rival task against the same session (buffer/session cross-talk). The previous turn is
        // awaited INSIDE the task — that is where serialization happens.
        let prev = channelGates[channelId]
        let task = Task { () -> TurnResult in
            if let prev { _ = try? await prev.value }
            return try await self.executeTurn(channelId: channelId, ownerId: ownerId, guildId: guildId, text: text, config: config)
        }
        channelGates[channelId] = task
        defer { if channelGates[channelId] == task { channelGates[channelId] = nil } }
        var result = try await task.value
        if let notice = fallbackNotice.removeValue(forKey: channelId) {
            result.text = notice + "\n\n" + result.text
        }
        return result
    }

    private func executeTurn(channelId: String, ownerId: String?, guildId: String, text: String, config: SessionConfig?) async throws -> TurnResult {
        let channel = try await ensureChannel(channelId: channelId, config: config, ownerId: ownerId, guildId: guildId)

        // Synchronous fold: the read loop runs this handler before resuming sessionPrompt, so the
        // buffer is complete when the await returns (see type comment). No actor hop for text/stats;
        // ToolActivityHost is an actor → fire-and-forget Task for Discord threads (Claude parity).
        let buf = LockedBox("")
        let statsBox = LockedBox(TurnToolStatsAggregator())
        let idSeq = LockedBox(0)
        let unsub = channel.client.onNotification { method, params in
            if case .appendText(let delta) = grokUpdateStep(method: method, params: params) {
                buf.withLock { $0 += delta }
                // W11-g residual: live stream text.
                let ch = channelId
                Task { await StreamStatusHost.shared.noteText(channelId: ch, delta: delta) }
            }
            // W16-g gap: agent_thought_chunk / plan → StreamStatusHost progress text.
            // Thought is not part of the reply buffer (TS thinking stream); plan reuses progress.
            let ch = channelId
            for pev in grokProgressEvents(method: method, params: params) {
                switch pev {
                case .thinking(let text, _):
                    // Delta-friendly: accumulate into the live embed body (not the answer buffer).
                    Task { await StreamStatusHost.shared.noteText(channelId: ch, delta: text) }
                case .progress(let label, let detail):
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

        let promptResult = try await channel.client.sessionPrompt(prompt: text)
        let out = buf.withLock { $0 }
        let textOut = out.isEmpty ? "(no text)" : out
        let (tools, agents) = statsBox.withLock { ($0.toolsSnapshot(), $0.agentsSnapshot()) }
        // W16-g: turn boundary for tool threads.
        await ToolActivityHost.shared.resetTurn(channelId: channelId)
        return TurnResult(
            text: textOut,
            usage: turnUsage(fromGrokPromptResult: promptResult),
            tools: tools,
            agents: agents
        )
    }

    private func ensureChannel(channelId: String, config: SessionConfig?, ownerId: String?, guildId: String) async throws -> Channel {
        // Reuse a live client; a closed one (crashed/EOF) is dropped and respawned
        // (mirrors CodexSessionBridge.ensureChannel).
        if let existing = channels[channelId] {
            if !existing.client.isClosed {
                return existing
            }
            await existing.client.close()
            channels[channelId] = nil
        }
        let epoch = stopEpoch[channelId] ?? 0
        // ponytail: model/effort/bypass are baked at spawn from the FIRST turn's config (TS parity —
        // Grok has no live setModel/setEffort). A later /perm change would need a respawn (W11-c+).

        // W11-c: bypass permMode → `--always-approve` (no handler). Non-bypass → route grok's
        // permission asks through the Discord gate (onPermission), deny-by-default on timeout.
        let gateTimeout = permGateTimeoutNs
        let gate = self.gate
        let onPermission: AcpPermissionHandler?
        if grokBypassPermMode(config?.permMode) {
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
                    ),
                    timeoutNs: gateTimeout
                )
                return decision.isAllowing ? .allow : .deny   // always|allow → allow; deny-by-default
            }
        }
        let client = try makeClient(config, onPermission)
        let persisted = await store.binding(channelId: channelId)

        do {
            _ = try await client.initialize()
            // W11-f2: load the stored session if any; on failure start a fresh one (F5).
            if let resumeId = persisted?.backendSessionId {
                do {
                    try await client.sessionLoad(sessionId: resumeId, cwd: cwd)
                    print("dab: grok session/load channel=\(channelId) sid=\(resumeId)")
                } catch {
                    fallbackNotice[channelId] = sessionFallbackNotice
                    _ = try await client.sessionNew(cwd: cwd)
                    print("dab: grok load failed (\(error)) → session/new channel=\(channelId)")
                }
            } else {
                _ = try await client.sessionNew(cwd: cwd)
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

        let channel = Channel(client: client)
        channels[channelId] = channel
        // F7: capture the grok session id + live context.
        await persistSession(store: store, backend: .grok, channelId: channelId, guildId: guildId, ownerId: ownerId, cwd: cwd, model: config?.model, effort: config?.effort, permMode: config?.permMode, backendSessionId: client.sessionId)
        if (stopEpoch[channelId] ?? 0) != epoch {
            channels[channelId] = nil
            await client.close()
            throw AcpClientError("session stopped")
        }
        print("dab: grok session channel=\(channelId) sid=\(client.sessionId ?? "?")")
        return channel
    }

    // MARK: - Lifecycle (W14)

    /// Hard-stop: close the grok child and drop the live channel entry (TS GrokAcpSession.stop).
    /// SessionStore resume id is left for `SessionLifecycle` to remove. Does NOT touch registry/store.
    public func stop(channelId: String) async {
        stopEpoch[channelId, default: 0] += 1
        channelGates[channelId]?.cancel()
        channelGates[channelId] = nil
        await ToolActivityHost.shared.dispose(channelId: channelId)
        guard let ch = channels.removeValue(forKey: channelId) else { return }
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
}

/// Whether a permMode auto-approves for Grok (→ `--always-approve`, no permission UI). No bound
/// permMode → true (danger default parity). Non-bypass modes route asks through the gate.
func grokBypassPermMode(_ permMode: String?) -> Bool {
    guard let permMode, !permMode.isEmpty else { return true }
    return permMode == "bypassPermissions" || permMode == "danger-full-access"
}

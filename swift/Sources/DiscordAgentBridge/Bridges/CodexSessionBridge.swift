import Foundation

/// Sibling of `DabSessionBridge` for the minimal `!codex` path (W10-c1). Same shape:
/// per-channel session, per-channel turn serialization, blocking runTurn that accumulates
/// text until the turn completes (or a timeout fallback), via a continuation.
///
/// Unlike Claude (one shared sidecar, many sessions), Codex uses **one `codex app-server`
/// child per channel** — matching TS `CodexAppSession` (one client per session,
/// src/modes/codex/appSession.ts:317) — so a client's notifications belong to that channel's
/// single thread and need no threadId routing.
public actor CodexSessionBridge {
    public static let shared = CodexSessionBridge()

    /// Client factory (test seam). The per-channel approval handler is passed at construction (the
    /// client stores it immutably), so the factory takes it. Default = real spawn. `@testable` in tests.
    private let makeClient: @Sendable (_ onApproval: AppServerApprovalHandler?) throws -> CodexAppServerClient
    /// Test seam: override the turn timeout (default nil → DAB_TURN_TIMEOUT_SEC env, floor 5s).
    private let turnTimeoutOverrideNs: UInt64?
    /// Permission gate (default shared; tests inject a fresh gate for isolation).
    private let gate: PermissionGate
    /// Session persistence (default shared; tests inject a temp-file store).
    private let store: SessionStore
    /// Global config (autoAllowClaudeTools host-side check for Always-Allow).
    private let configStore: ConfigStore

    init(
        makeClient: @escaping @Sendable (_ onApproval: AppServerApprovalHandler?) throws -> CodexAppServerClient = { onApproval in
            let spawn = resolveCodexSpawn()
            print("dab: spawning codex app-server: \(spawn.command) \(spawn.args.joined(separator: " "))")
            return try CodexAppServerClient(spawn: spawn, requestTimeoutMs: 120_000, onApproval: onApproval)
        },
        turnTimeoutOverrideNs: UInt64? = nil,
        gate: PermissionGate = .shared,
        store: SessionStore = .shared,
        configStore: ConfigStore = .shared
    ) {
        self.makeClient = makeClient
        self.turnTimeoutOverrideNs = turnTimeoutOverrideNs
        self.gate = gate
        self.store = store
        self.configStore = configStore
    }

    /// One-shot resume-failure notice to prepend to the next reply (F5).
    private var fallbackNotice: [String: String] = [:]

    private struct Channel {
        let client: CodexAppServerClient
        let threadId: String
    }

    /// channelId (snowflake string) → codex client + thread
    private var channels: [String: Channel] = [:]
    /// channelId → in-flight turn accumulator
    private var turns: [String: TurnBox] = [:]
    /// channelId → turn id from the latest `turn/start` (needed for `turn/interrupt`; W14).
    private var activeTurnIds: [String: String] = [:]
    /// channelId → generation bumped on interrupt/stop so a late `turn/start` result cannot
    /// re-stamp a zombie activeTurnId (W14 RV).
    private var turnGens: [String: UInt64] = [:]
    /// channelId → epoch bumped on `stop` so ensureChannel that races mid-await closes the orphan.
    private var stopEpoch: [String: UInt64] = [:]
    /// Serialize turns per channel (avoid concurrent turn/start on the same thread).
    private var channelGates: [String: Task<TurnResult, Error>] = [:]
    /// Per-channel count of `runTurn` callers (in-flight + waiting). G-P2-04 stats.
    private var turnDepth: [String: Int] = [:]
    /// childThreadId → spawn tool_use id (TS CodexAppSession.parentByThread). Session-scoped
    /// so collab child-thread tools keep routing after spawn across the client lifetime.
    private var parentByThread: [String: [String: String]] = [:]
    /// Per-channel FIFO chain so delta → completed notifications cannot reorder across the
    /// sync-handler → actor hop (`Task { await onNotification }`). Under parallel load a
    /// bare Task hop can finish the turn before appendText, yielding "(empty result)".
    private let notifyChains = LockedBox<[String: Task<Void, Never>]>([:])

    private struct TurnBox {
        var text = ""
        var usage: TurnUsage?
        /// C2: latest `thread/tokenUsage/updated` snapshot (kept, not emitted mid-turn).
        var contextUsage: ContextUsageInfo?
        /// Turn-local tools/subagent HUD + ToolActivityHost feed (W16-g residual).
        var stats = TurnToolStatsAggregator()
        /// Mint ids for codex items that lack `id` / `itemId`.
        var toolIdSeq = 0
        var done = false
        var continuation: CheckedContinuation<TurnResult, Error>?
        var timeoutTask: Task<Void, Never>?
    }

    private func makeTurnResult(box: TurnBox, text: String) -> TurnResult {
        TurnResult(
            text: text,
            usage: box.usage,
            contextUsage: box.contextUsage,
            tools: box.stats.toolsSnapshot(),
            agents: box.stats.agentsSnapshot()
        )
    }

    // env rules copied from DabSessionBridge (B/"sibling bridge": no forced sharing).
    private var cwd: String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["DAB_CWD"], !v.isEmpty { return v }
        return NSHomeDirectory()
    }

    private var turnTimeoutNs: UInt64 {
        if let turnTimeoutOverrideNs { return turnTimeoutOverrideNs }
        let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 120
        return UInt64(max(5, sec)) * 1_000_000_000
    }

    // ponytail: permission-button deadline < turn timeout so an unanswered ask denies in time.
    private var permGateTimeoutNs: UInt64 { turnTimeoutNs / 2 }

    /// Send user text for a Discord channel; wait for accumulated text + completion (or timeout).
    /// Turns on the same channel are serialized. Token usage from `turn/completed` is returned
    /// when present (W11-g slice1).
    /// `files`: images go out as `localImage` input items (Codex reads the path itself), everything
    /// else as a text hint (`buildCodexTurnItems`, TS `appSession.ts:486-498` parity).
    public func runTurn(channelId: String, ownerId: String? = nil, guildId: String = "", text: String, config: SessionConfig? = nil, files: [TurnFile] = []) async throws -> TurnResult {
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

    /// G-P2-04: turns waiting behind the running one (TS `queueDepth`).
    public func turnQueueDepth(channelId: String) -> Int {
        max(0, (turnDepth[channelId] ?? 0) - 1)
    }

    private func executeTurn(channelId: String, ownerId: String?, guildId: String, text: String, config: SessionConfig?, files: [TurnFile]) async throws -> TurnResult {
        let channel = try await ensureChannel(channelId: channelId, config: config, ownerId: ownerId, guildId: guildId)
        // Multimodal: images → `localImage` input items; everything else → text hint.
        let inputItems = buildCodexTurnItems(text: text, files: files)
        let timeoutNs = turnTimeoutNs
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TurnResult, Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard !Task.isCancelled else { return }
                self.finishTurn(channelId: channelId, error: nil, timeoutFallback: true)
            }
            turns[channelId] = TurnBox(
                text: "",
                usage: nil,
                done: false,
                continuation: cont,
                timeoutTask: timeoutTask
            )

            // W11-b1: model/effort from the bound session config. permMode → approvalPolicy/sandbox
            // stays hardcoded (danger) until the permission UI lands (W11-c).
            var input: [String: JSONValue] = [
                "threadId": .string(channel.threadId),
                "input": .array(inputItems),
            ]
            if let effort = config?.effort, !effort.isEmpty { input["effort"] = .string(effort) }
            if let model = config?.model, !model.isEmpty { input["model"] = .string(model) }

            // Generation tokens this turnStart; interrupt/stop bump so a late result cannot zombie-stamp.
            let gen = (turnGens[channelId] ?? 0) + 1
            turnGens[channelId] = gen
            let threadId = channel.threadId
            let client = channel.client
            Task {
                do {
                    let turnId = try await client.turnStart(params: .object(input))
                    await self.noteTurnStarted(
                        channelId: channelId,
                        gen: gen,
                        turnId: turnId,
                        threadId: threadId,
                        client: client
                    )
                } catch {
                    await self.noteTurnStartFailed(channelId: channelId, gen: gen, error: error)
                }
            }
        }
    }

    /// Apply a turn/start id only if this generation is still current and the turn is live;
    /// otherwise best-effort `turn/interrupt` so a late id after interrupt does not leave a zombie.
    private func noteTurnStarted(
        channelId: String,
        gen: UInt64,
        turnId: String,
        threadId: String,
        client: CodexAppServerClient
    ) async {
        guard turnGens[channelId] == gen else {
            _ = try? await client.turnInterrupt(params: .object([
                "threadId": .string(threadId),
                "turnId": .string(turnId),
            ]))
            return
        }
        guard let box = turns[channelId], !box.done else {
            _ = try? await client.turnInterrupt(params: .object([
                "threadId": .string(threadId),
                "turnId": .string(turnId),
            ]))
            return
        }
        activeTurnIds[channelId] = turnId
    }

    private func noteTurnStartFailed(channelId: String, gen: UInt64, error: Error) {
        guard turnGens[channelId] == gen else { return }
        finishTurn(channelId: channelId, error: error)
    }

    private func ensureChannel(channelId: String, config: SessionConfig?, ownerId: String?, guildId: String) async throws -> Channel {
        // Reuse a live client; a closed one (crashed/EOF) is dropped and respawned
        // (mirrors TS appSession.ts:296 `if (this.client && !this.client.isClosed) return`).
        if let existing = channels[channelId] {
            if !existing.client.isClosed {
                return existing
            }
            await existing.client.close()
            channels[channelId] = nil
        }
        let epoch = stopEpoch[channelId] ?? 0
        // W11-c: permMode → approvalPolicy/sandbox (resolveThreadPolicy). Default bypassPermissions
        // (danger) preserved when no permMode bound. A non-auto policy routes Codex approval requests
        // through the Discord permission gate; an auto policy needs no handler (nil).
        let policy = resolveThreadPolicy(permMode: config?.permMode ?? "bypassPermissions")
        let gateTimeout = permGateTimeoutNs
        let gate = self.gate
        let onApproval: AppServerApprovalHandler?
        if isAutoApprovePolicy(policy) {
            onApproval = nil   // auto-approve: no Discord prompt needed
        } else {
            let configStore = self.configStore
            onApproval = { req in
                let toolName = codexApprovalToolName(req)
                // W16-e: always-allowed tools skip the Discord button.
                if await isAutoAllowedClaudeTool(toolName, store: configStore) {
                    return .accept
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
                return decision.isAllowing ? .accept : .decline   // always|allow → accept; deny-by-default
            }
        }
        let client = try makeClient(onApproval)
        let persisted = await store.binding(channelId: channelId)

        var startParams: [String: JSONValue] = [
            "cwd": .string(cwd),
            "approvalPolicy": .string(policy.approvalPolicy),
            "sandbox": .string(policy.sandbox),
        ]
        if let model = config?.model, !model.isEmpty { startParams["model"] = .string(model) }

        let threadId: String
        do {
            _ = try await client.initialize()
            // W11-f2: resume the stored thread if any; on failure start a fresh one (F5).
            if let resumeId = persisted?.backendSessionId {
                do {
                    _ = try await client.threadResume(params: .object(["threadId": .string(resumeId)]))
                    threadId = resumeId
                    print("dab: codex thread/resume channel=\(channelId) thread=\(resumeId)")
                } catch {
                    fallbackNotice[channelId] = sessionFallbackNotice
                    threadId = try await client.threadStart(params: .object(startParams))
                    print("dab: codex resume failed (\(error)) → thread/start channel=\(channelId)")
                }
            } else {
                threadId = try await client.threadStart(params: .object(startParams))
            }
        } catch {
            // Init failed: close the spawned child so it does not leak as an orphan.
            await client.close()
            throw error
        }

        // stop raced mid-ensure → close orphan, do not publish.
        if (stopEpoch[channelId] ?? 0) != epoch {
            await client.close()
            throw AppServerError("session stopped")
        }

        // Extend the chain *synchronously* in the read-loop callback so arrival order is kept
        // even when work hops onto this actor.
        client.onNotification { [weak self] method, params in
            guard let self else { return }
            self.notifyChains.withLock { chains in
                let prev = chains[channelId]
                let next = Task {
                    _ = await prev?.value
                    await self.onNotification(channelId: channelId, method: method, params: params)
                }
                chains[channelId] = next
            }
        }
        let channel = Channel(client: client, threadId: threadId)
        channels[channelId] = channel
        // F7: capture the thread id (= backend session) + live context.
        await persistSession(store: store, backend: .codex, channelId: channelId, guildId: guildId, ownerId: ownerId, cwd: cwd, model: config?.model, effort: config?.effort, permMode: config?.permMode, backendSessionId: threadId)
        // stop during persist → drop the just-published channel.
        if (stopEpoch[channelId] ?? 0) != epoch {
            channels[channelId] = nil
            await client.close()
            throw AppServerError("session stopped")
        }
        print("dab: codex thread channel=\(channelId) thread=\(threadId)")
        return channel
    }

    private func onNotification(channelId: String, method: String, params: JSONValue?) {
        guard var box = turns[channelId], !box.done else { return }

        // C2: thread/tokenUsage/updated → keep the latest context_usage snapshot; makeTurnResult
        // surfaces it once via TurnResult.contextUsage at turn end (TS appSession.ts:211-219,
        // not emitted mid-turn since this notification fires many times per turn).
        if let ctx = codexContextUsage(method: method, params: params) {
            box.contextUsage = ctx
            turns[channelId] = box
        }

        // G-P1-02: item/started + turn/started → stream embed progress (TS transcriptFeed).
        // C1: item/reasoning/delta(+aliases) → thinking (TS eventMapper.ts:171-184).
        let progressEvs = codexProgressEvents(method: method, params: params)
        if !progressEvs.isEmpty {
            let ch = channelId
            for ev in progressEvs {
                switch ev {
                case .progress(let label, let detail):
                    Task {
                        await StreamStatusHost.shared.noteProgress(
                            channelId: ch, label: label, detail: detail
                        )
                    }
                case .thinking(let text, _):
                    Task { await StreamStatusHost.shared.noteThinking(channelId: ch, delta: text) }
                default:
                    break
                }
            }
        }

        // W16-g residual: tool_use / tool_result mid-turn → stats + Discord work threads.
        // parentByThread mutates on collab spawnAgent (TS MapContext.onSpawnThread).
        var parentMap = parentByThread[channelId] ?? [:]
        let toolEvs = codexToolEvents(
            method: method,
            params: params,
            mintId: &box.toolIdSeq,
            parentByThread: &parentMap
        )
        parentByThread[channelId] = parentMap
        if !toolEvs.isEmpty {
            for ev in toolEvs {
                box.stats.note(ev)
                let ch = channelId
                Task { await ToolActivityHost.shared.handle(channelId: ch, event: ev) }
                if case .toolUse = ev {
                    Task { await StreamStatusHost.shared.noteToolUse(channelId: ch) }
                }
            }
            turns[channelId] = box
        }

        switch codexTurnStep(method: method, params: params) {
        case .appendText(let delta):
            box.text += delta
            turns[channelId] = box
            // W11-g residual: live stream text (same path as Claude).
            let ch = channelId
            Task { await StreamStatusHost.shared.noteText(channelId: ch, delta: delta) }
        case .fullText(let text):
            // Only when no deltas streamed (avoids duplicating the streamed message).
            if box.text.isEmpty {
                box.text = text
                turns[channelId] = box
            }
        case .finished(let usage):
            if let usage { box.usage = usage }
            turns[channelId] = box
            let text = box.text.isEmpty ? "(empty result)" : box.text
            finishTurnUnlocked(channelId: channelId, result: makeTurnResult(box: box, text: text))
        case .failed(let message):
            finishTurnUnlocked(channelId: channelId, result: nil, error: AppServerError(message))
        case .ignore:
            break
        }
    }

    private func finishTurn(channelId: String, error: Error?, timeoutFallback: Bool = false) {
        guard let box = turns[channelId], !box.done else { return }
        if let error {
            finishTurnUnlocked(channelId: channelId, result: nil, error: error)
            return
        }
        if timeoutFallback {
            if box.text.isEmpty {
                finishTurnUnlocked(
                    channelId: channelId,
                    result: nil,
                    error: AppServerError("codex turn timeout (no text)")
                )
            } else {
                finishTurnUnlocked(
                    channelId: channelId,
                    result: makeTurnResult(box: box, text: box.text + "\n…(timeout)")
                )
            }
        }
    }

    private func finishTurnUnlocked(channelId: String, result: TurnResult?, error: Error? = nil) {
        guard var box = turns[channelId], !box.done else { return }
        box.done = true
        box.timeoutTask?.cancel()
        let cont = box.continuation
        box.continuation = nil
        box.timeoutTask = nil
        turns[channelId] = box
        activeTurnIds[channelId] = nil
        // W16-g: turn boundary for tool threads.
        Task { await ToolActivityHost.shared.resetTurn(channelId: channelId) }
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: result ?? makeTurnResult(box: box, text: box.text))
        }
    }

    // MARK: - Lifecycle (W14)

    /// Kill the channel's codex app-server child and drop maps (TS CodexSession.stop / dropClient).
    /// Does NOT touch SessionRegistry / SessionStore.
    public func stop(channelId: String) async {
        stopEpoch[channelId, default: 0] += 1
        turnGens[channelId, default: 0] += 1
        channelGates[channelId]?.cancel()
        channelGates[channelId] = nil
        turnDepth[channelId] = nil
        if let box = turns[channelId], !box.done {
            finishTurnUnlocked(
                channelId: channelId,
                result: nil,
                error: AppServerError("session stopped")
            )
        }
        turns[channelId] = nil
        activeTurnIds[channelId] = nil
        parentByThread[channelId] = nil
        await ToolActivityHost.shared.dispose(channelId: channelId)
        guard let ch = channels.removeValue(forKey: channelId) else { return }
        await ch.client.close()
    }

    /// Cancel the in-flight turn via `turn/interrupt` without closing the client/thread
    /// (TS CodexSession.interrupt). Returns `true` when a live channel session existed.
    /// Bumps turn generation so a late turn/start result cannot re-stamp activeTurnId.
    public func interrupt(channelId: String) async -> Bool {
        guard let ch = channels[channelId] else { return false }
        turnGens[channelId, default: 0] += 1
        if let turnId = activeTurnIds[channelId] {
            _ = try? await ch.client.turnInterrupt(params: .object([
                "threadId": .string(ch.threadId),
                "turnId": .string(turnId),
            ]))
        }
        if let box = turns[channelId], !box.done {
            let partial = box.text.isEmpty ? "(interrupted)" : box.text
            finishTurnUnlocked(channelId: channelId, result: makeTurnResult(box: box, text: partial))
        } else {
            activeTurnIds[channelId] = nil
        }
        return true
    }

    /// Test/inspection: whether this channel still holds a live codex client.
    public func isLive(channelId: String) -> Bool {
        channels[channelId] != nil
    }

    /// G-P1-05: open/resume the Codex thread without a user turn. No-op when already live.
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
            print("dab: codex softEnsure failed channel=\(channelId) error=\(error)")
            return false
        }
    }

    /// Test/inspection: turn id from the latest `turn/start` (nil when idle).
    public func activeTurnId(channelId: String) -> String? {
        activeTurnIds[channelId]
    }

    /// Test/inspection: current turn generation (bumped on interrupt/stop).
    public func turnGeneration(channelId: String) -> UInt64 {
        turnGens[channelId] ?? 0
    }
}

/// Multimodal turn input: text + `localImage` paths (Codex `UserInput.localImage` reads the file
/// itself — no base64 needed). Mirrors TS `buildCodexTurnInput` (`appSession.ts:486-498`).
func buildCodexTurnItems(text: String, files: [TurnFile]) -> [JSONValue] {
    let classified = classifyTurnFiles(files)
    let images = classified.filter { $0.isImage }
    let nonImages = classified.filter { !$0.isImage }
    let hinted = appendAttachedFileHints(text: text, files: nonImages.map { TurnFile(path: $0.path, mime: $0.mime) })
    var items: [JSONValue] = []
    if !hinted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        items.append(.object(["type": .string("text"), "text": .string(hinted)]))
    }
    for img in images {
        items.append(.object(["type": .string("localImage"), "path": .string(img.path)]))
    }
    if items.isEmpty { items.append(.object(["type": .string("text"), "text": .string(" ")])) }
    return items
}

/// Short tool label for a Codex approval prompt (mirrors TS deriveApprovalToolName, appSession.ts).
private func codexApprovalToolName(_ req: AppServerApprovalRequest) -> String {
    if case .object(let p)? = req.params {
        if p["command"] != nil { return "shell" }
        if let tool = p["tool"]?.stringValue { return tool }
        if let name = p["name"]?.stringValue { return name }
    }
    if req.method.contains("commandExecution") { return "shell" }
    if req.method.contains("fileChange") { return "apply_patch" }
    return "tool"
}

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

    private struct TurnBox {
        var text = ""
        var usage: TurnUsage?
        var done = false
        var continuation: CheckedContinuation<TurnResult, Error>?
        var timeoutTask: Task<Void, Never>?
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
                "input": .array([.object(["type": .string("text"), "text": .string(text)])]),
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

        client.onNotification { [weak self] method, params in
            Task { await self?.onNotification(channelId: channelId, method: method, params: params) }
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
        switch codexTurnStep(method: method, params: params) {
        case .appendText(let delta):
            box.text += delta
            turns[channelId] = box
        case .fullText(let text):
            // Only when no deltas streamed (avoids duplicating the streamed message).
            if box.text.isEmpty {
                box.text = text
                turns[channelId] = box
            }
        case .finished(let usage):
            if let usage { box.usage = usage; turns[channelId] = box }
            let text = box.text.isEmpty ? "(empty result)" : box.text
            finishTurnUnlocked(channelId: channelId, result: TurnResult(text: text, usage: box.usage))
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
                    result: TurnResult(text: box.text + "\n…(timeout)", usage: box.usage)
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
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: result ?? TurnResult(text: box.text, usage: box.usage))
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
        if let box = turns[channelId], !box.done {
            finishTurnUnlocked(
                channelId: channelId,
                result: nil,
                error: AppServerError("session stopped")
            )
        }
        turns[channelId] = nil
        activeTurnIds[channelId] = nil
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
            finishTurnUnlocked(channelId: channelId, result: TurnResult(text: partial, usage: box.usage))
        } else {
            activeTurnIds[channelId] = nil
        }
        return true
    }

    /// Test/inspection: whether this channel still holds a live codex client.
    public func isLive(channelId: String) -> Bool {
        channels[channelId] != nil
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

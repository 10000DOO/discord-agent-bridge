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

    init(
        makeClient: @escaping @Sendable () throws -> ClaudeSidecarClient = {
            let spawn = resolveClaudeSidecarSpawn()
            print("dab: spawning claude sidecar: \(spawn.command) \(spawn.args.joined(separator: " "))")
            return try ClaudeSidecarClient(spawn: spawn, requestTimeoutMs: 120_000)
        },
        turnTimeoutOverrideNs: UInt64? = nil,
        gate: PermissionGate = .shared,
        store: SessionStore = .shared
    ) {
        self.makeClient = makeClient
        self.turnTimeoutOverrideNs = turnTimeoutOverrideNs
        self.gate = gate
        self.store = store
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
    /// Serialize turns per channel (avoid concurrent send on same session).
    private var channelGates: [String: Task<String, Error>] = [:]

    private struct TurnBox {
        var text = ""
        var done = false
        var continuation: CheckedContinuation<String, Error>?
        var timeoutTask: Task<Void, Never>?
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

    // ponytail: invariant — the permission-button deadline must be SHORTER than the turn timeout so
    // an unanswered ask denies (and the tool result flows) before the whole turn times out.
    private var permGateTimeoutNs: UInt64 { turnTimeoutNs / 2 }

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

    /// Send user text for a Discord channel; wait for accumulated text + result (or timeout).
    /// Turns on the same channel are serialized.
    public func runTurn(
        channelId: String,
        guildId: String,
        ownerId: String?,
        text: String,
        config: SessionConfig? = nil
    ) async throws -> String {
        // Read + install the gate with NO await between them, so a reentering job cannot install a
        // rival task against the same session. The previous turn is awaited INSIDE the task — that
        // is where serialization happens.
        let prev = channelGates[channelId]
        let task = Task { () -> String in
            if let prev { _ = try? await prev.value }
            return try await self.executeTurn(
                channelId: channelId,
                guildId: guildId,
                ownerId: ownerId,
                text: text,
                config: config
            )
        }
        channelGates[channelId] = task
        defer { if channelGates[channelId] == task { channelGates[channelId] = nil } }
        let reply = try await task.value
        // F5: prepend the resume-failure notice once, if this turn fell back to a fresh session.
        if let notice = fallbackNotice.removeValue(forKey: channelId) { return notice + "\n\n" + reply }
        return reply
    }

    private func executeTurn(
        channelId: String,
        guildId: String,
        ownerId: String?,
        text: String,
        config: SessionConfig?
    ) async throws -> String {
        let client = try await ensureClient()
        let handle = try await sessionHandle(
            client: client,
            channelId: channelId,
            guildId: guildId,
            ownerId: ownerId,
            config: config
        )

        let timeoutNs = turnTimeoutNs
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard !Task.isCancelled else { return }
                self.finishTurn(handle: handle, error: nil, timeoutFallback: true)
            }
            turns[handle] = TurnBox(
                text: "",
                done: false,
                continuation: cont,
                timeoutTask: timeoutTask
            )

            Task {
                do {
                    try await client.sessionSend(session: handle, text: text)
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
        // W11-f2: resume params reuse the STORED model/effort/permMode (T6) so a reconnect keeps the
        // original session's settings; live config/env fill in when nothing was persisted.
        let persisted = await store.binding(channelId: channelId)
        let model = persisted?.model ?? config?.model
        let effort = persisted?.effort ?? config?.effort
        let perm = persisted?.permMode ?? config?.permMode ?? permMode
        let cwdValue = cwd
        let params = SessionStartParams(
            cwd: cwdValue, guildId: guildId, channelId: channelId, ownerId: ownerId,
            model: model, effort: effort, permMode: perm
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
        sessions[channelId] = handle
        sessionMeta[handle] = (channelId: channelId, approverId: ownerId)
        let store = self.store
        client.registerSessionHandlers(
            handle: handle,
            handlers: SidecarSessionHandlers(
                onEvent: { [weak self] ev in Task { await self?.onEvent(handle: handle, event: ev) } },
                // F7 / T3: Claude's backend id may arrive only after init — persist it when it lands.
                onBackendId: { backendId in
                    Task { await persistSession(store: store, backend: .claude, channelId: channelId, guildId: guildId, ownerId: ownerId, cwd: cwdValue, model: model, effort: effort, permMode: perm, backendSessionId: backendId) }
                }
            )
        )
        // F7: if start/resume already gave a backend id, persist it now. If null (T3), the onBackendId
        // notify above records it later — we do NOT persist a null id here.
        if let bid = started.backendSessionId {
            await persistSession(store: store, backend: .claude, channelId: channelId, guildId: guildId, ownerId: ownerId, cwd: cwdValue, model: model, effort: effort, permMode: perm, backendSessionId: bid)
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
        case .result(let t, _, _, _, _):
            if let t, !t.isEmpty {
                if box.text.isEmpty {
                    box.text = t
                } else if !box.text.contains(t) {
                    box.text += t
                }
            }
            turns[handle] = box
            let out = box.text.isEmpty ? "(empty result)" : box.text
            finishTurnUnlocked(handle: handle, result: out)
        case .error(let message, _):
            finishTurnUnlocked(
                handle: handle,
                result: nil,
                error: SidecarRpcError(code: "sdk_error", message: message)
            )
        case .permissionRequest(let id, let toolName, let input):
            // Ask the owner via Discord buttons; deny-by-default on timeout. Answer the sidecar with
            // the decision so the tool proceeds/aborts. Does not touch the turn accumulator.
            let meta = sessionMeta[handle]
            let prompt = PermissionPrompt(
                reqKey: UUID().uuidString,
                channelId: meta?.channelId ?? "",
                toolName: toolName,
                detail: permissionDetail(input),
                approverId: meta?.approverId
            )
            let timeout = permGateTimeoutNs
            let client = self.client
            Task {
                let decision = await self.gate.await(prompt: prompt, timeoutNs: timeout)
                try? await client?.sessionPermission(session: handle, requestId: id, behavior: decision.rawValue)
            }
        default:
            break
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
                finishTurnUnlocked(handle: handle, result: box.text + "\n…(timeout)")
            }
        }
    }

    private func finishTurnUnlocked(handle: String, result: String?, error: Error? = nil) {
        guard var box = turns[handle], !box.done else { return }
        box.done = true
        box.timeoutTask?.cancel()
        let cont = box.continuation
        box.continuation = nil
        box.timeoutTask = nil
        turns[handle] = box
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: result ?? box.text)
        }
    }
}

/// Short human hint for the permission button message (e.g. the shell command). Best-effort.
private func permissionDetail(_ input: JSONValue) -> String? {
    if let c = input["command"]?.stringValue, !c.isEmpty { return c }
    if let p = input["file_path"]?.stringValue, !p.isEmpty { return p }
    return nil
}

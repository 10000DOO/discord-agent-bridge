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

    init(
        makeClient: @escaping @Sendable (_ onApproval: AppServerApprovalHandler?) throws -> CodexAppServerClient = { onApproval in
            let spawn = resolveCodexSpawn()
            print("dab: spawning codex app-server: \(spawn.command) \(spawn.args.joined(separator: " "))")
            return try CodexAppServerClient(spawn: spawn, requestTimeoutMs: 120_000, onApproval: onApproval)
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
    /// Serialize turns per channel (avoid concurrent turn/start on the same thread).
    private var channelGates: [String: Task<String, Error>] = [:]

    private struct TurnBox {
        var text = ""
        var done = false
        var continuation: CheckedContinuation<String, Error>?
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
    /// Turns on the same channel are serialized.
    public func runTurn(channelId: String, ownerId: String? = nil, guildId: String = "", text: String, config: SessionConfig? = nil) async throws -> String {
        // Read + install the gate with NO await between them, so a reentering job cannot install a
        // rival task against the same session (buffer/session cross-talk). The previous turn is
        // awaited INSIDE the task — that is where serialization happens.
        let prev = channelGates[channelId]
        let task = Task { () -> String in
            if let prev { _ = try? await prev.value }
            return try await self.executeTurn(channelId: channelId, ownerId: ownerId, guildId: guildId, text: text, config: config)
        }
        channelGates[channelId] = task
        defer { if channelGates[channelId] == task { channelGates[channelId] = nil } }
        let reply = try await task.value
        if let notice = fallbackNotice.removeValue(forKey: channelId) { return notice + "\n\n" + reply }
        return reply
    }

    private func executeTurn(channelId: String, ownerId: String?, guildId: String, text: String, config: SessionConfig?) async throws -> String {
        let channel = try await ensureChannel(channelId: channelId, config: config, ownerId: ownerId, guildId: guildId)
        let timeoutNs = turnTimeoutNs
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard !Task.isCancelled else { return }
                self.finishTurn(channelId: channelId, error: nil, timeoutFallback: true)
            }
            turns[channelId] = TurnBox(
                text: "",
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

            Task {
                do {
                    _ = try await channel.client.turnStart(params: .object(input))
                } catch {
                    self.finishTurn(channelId: channelId, error: error)
                }
            }
        }
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
        // ponytail: channel당 codex 자식 프로세스가 상주하고 정리 경로가 없음(무한 증가 ceiling).
        // W11에서 세션 수명 배선 시 close() + channels 제거로 업그레이드.

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
            onApproval = { req in
                let decision = await gate.await(
                    prompt: PermissionPrompt(
                        reqKey: UUID().uuidString,
                        channelId: channelId,
                        toolName: codexApprovalToolName(req),
                        approverId: ownerId
                    ),
                    timeoutNs: gateTimeout
                )
                return decision == .allow ? .accept : .decline   // deny-by-default via gate timeout
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

        client.onNotification { [weak self] method, params in
            Task { await self?.onNotification(channelId: channelId, method: method, params: params) }
        }
        let channel = Channel(client: client, threadId: threadId)
        channels[channelId] = channel
        // F7: capture the thread id (= backend session) + live context.
        await persistSession(store: store, backend: .codex, channelId: channelId, guildId: guildId, ownerId: ownerId, cwd: cwd, model: config?.model, effort: config?.effort, permMode: config?.permMode, backendSessionId: threadId)
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
        case .finished:
            finishTurnUnlocked(channelId: channelId, result: box.text.isEmpty ? "(empty result)" : box.text)
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
                finishTurnUnlocked(channelId: channelId, result: box.text + "\n…(timeout)")
            }
        }
    }

    private func finishTurnUnlocked(channelId: String, result: String?, error: Error? = nil) {
        guard var box = turns[channelId], !box.done else { return }
        box.done = true
        box.timeoutTask?.cancel()
        let cont = box.continuation
        box.continuation = nil
        box.timeoutTask = nil
        turns[channelId] = box
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: result ?? box.text)
        }
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
